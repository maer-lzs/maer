// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The SERVER is the source of the FEED LIST, not a new playback provider.
/// Its per-channel feeds are plain RSS and ride the existing `rss:` path, so
/// there is no new namespace and no router entry.
///
/// What the server contributes: (a) the list (`/sources/opml` instead of
/// hand-adding channels) and (b) the provenance per feed.
///
/// Hard rules: the `route_token` lives in the KEYCHAIN and is
/// NEVER logged. Log lines carry the host only, never a URL with the token
/// query. Verified at the live test stand: the OPML's xmlUrls come WITHOUT
/// the token; the feeds themselves authenticate via Basic Auth.
@MainActor
enum PinchflatClient {
    // MARK: - Keychain (host-scoped)

    private static func tokenKey(_ host: String) -> String { "pinchflat.routeToken.\(host)" }
    private static func loginKey(_ host: String) -> String { "pinchflat.login.\(host)" }
    private static let serverDefaultsKey = "pinchflatServerURL"

    /// The configured server base URL (UserDefaults. It is an address, not a
    /// secret; the secrets live in the keychain).
    static var serverURL: URL? {
        get { UserDefaults.standard.string(forKey: serverDefaultsKey).flatMap(URL.init) }
    }

    /// Normalize a typed address. Trim, and prepend `https://`
    /// when no scheme is given (`tube.x.y` parses host-less in Foundation,
    /// which used to make saving a silent no-op). Returns nil only for input
    /// that has no host even after normalization.
    nonisolated static func normalizedServerURL(from raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let url = URL(string: trimmed), url.host != nil else { return nil }
        return url
    }

    /// Saving and removing are TWO paths. A bad NEW entry can
    /// never land in a delete branch and destroy the existing configuration.
    /// Callers validate via `normalizedServerURL` and show a visible form
    /// error instead.
    static func setServer(url: URL, routeToken: String?, user: String?, password: String?) {
        guard let host = url.host else { return }
        UserDefaults.standard.set(url.absoluteString, forKey: serverDefaultsKey)
        if let routeToken, !routeToken.isEmpty {
            KeychainStore.save(routeToken, forKey: tokenKey(host))
        }
        if let user, let password, !user.isEmpty {
            KeychainStore.save("\(user)\n\(password)", forKey: loginKey(host))
        }
    }

    /// The explicit remove path of the management surface.
    static func disconnect() {
        if let old = serverURL?.host {
            KeychainStore.delete(forKey: tokenKey(old))
            KeychainStore.delete(forKey: loginKey(old))
        }
        UserDefaults.standard.removeObject(forKey: serverDefaultsKey)
    }

    static func credentials(host: String) -> (user: String, password: String)? {
        guard let raw = KeychainStore.load(forKey: loginKey(host)),
              let sep = raw.firstIndex(of: "\n") else { return nil }
        return (String(raw[..<sep]), String(raw[raw.index(after: sep)...]))
    }

    static func routeToken(host: String) -> String? {
        KeychainStore.load(forKey: tokenKey(host))
    }

    // MARK: - OPML

    enum FetchError: Error {
        /// 401. Token or login wrong. Its own case so the surface can say so.
        case unauthorized
        /// Anything transport-shaped. For a mesh-only server this is a NORMAL
        /// state (unterwegs), not an app defect. Surfaces word it that way.
        case unreachable
        case badAnswer
    }

    /// The channel list. Verified shape: `<outline type="rss" text="…"
    /// xmlUrl="https://host/sources/<uuid>/feed.xml" />`. Parsed by the ONE
    /// existing OPML parser.
    static func fetchFeedURLs() async throws -> [String] {
        guard let base = serverURL, let host = base.host else { throw FetchError.unreachable }
        var comp = URLComponents(url: base.appendingPathComponent("sources/opml"),
                                 resolvingAgainstBaseURL: false)
        if let token = routeToken(host: host), !token.isEmpty {
            comp?.queryItems = [URLQueryItem(name: "route_token", value: token)]
        }
        guard let url = comp?.url else { throw FetchError.unreachable }
        var request = URLRequest(url: url, timeoutInterval: 15)
        if let login = credentials(host: host) {
            let raw = Data("\(login.user):\(login.password)".utf8).base64EncodedString()
            request.setValue("Basic \(raw)", forHTTPHeaderField: "Authorization")
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // Host only. Never the URL (it carries the token query).
            Logger.rss.notice("PINCHFLAT opml unreachable host=\(host, privacy: .public)")
            throw FetchError.unreachable
        }
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            Logger.rss.notice("PINCHFLAT opml 401 host=\(host, privacy: .public)")
            throw FetchError.unauthorized
        }
        guard let urls = PodcastImport.parseOPML(data), !urls.isEmpty else {
            Logger.rss.notice("PINCHFLAT opml empty/bad host=\(host, privacy: .public)")
            throw FetchError.badAnswer
        }
        Logger.rss.notice("PINCHFLAT opml host=\(host, privacy: .public) feeds=\(urls.count)")
        return urls
    }
}


/// The mirror run. Connect = done, server = source of truth.
/// The APP-START mirror fails SILENTLY (a mesh-only
/// server being away is normal); visible errors belong to the manual
/// gesture (connect / refresh) only.
@MainActor
enum PinchflatSync {
    private static let hiddenKey = "pinchflatHiddenFeeds"
    /// Remembered titles for the hidden list. The management
    /// surface shows channel names, not opaque feed UUIDs.
    private static let hiddenTitlesKey = "pinchflatHiddenTitles"
    private static var didRunThisSession = false

    static func hiddenFeeds() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
    }

    /// Hidden channels with their remembered display titles (management list).
    static func hiddenEntries() -> [(feedURL: String, title: String)] {
        let titles = UserDefaults.standard.dictionary(forKey: hiddenTitlesKey) as? [String: String] ?? [:]
        return hiddenFeeds().sorted().map { ($0, titles[$0] ?? $0) }
    }

    /// The opt-out exception: hidden survives mirror runs.
    /// The visible GESTURE calls this from the context menu on the
    /// group tile / grid cell.
    static func hide(feedURL: String, title: String? = nil) {
        var set = hiddenFeeds(); set.insert(feedURL)
        UserDefaults.standard.set(Array(set).sorted(), forKey: hiddenKey)
        if let title {
            var titles = UserDefaults.standard.dictionary(forKey: hiddenTitlesKey) as? [String: String] ?? [:]
            titles[feedURL] = title
            UserDefaults.standard.set(titles, forKey: hiddenTitlesKey)
        }
        PodcastSubscriptions.shared.removeMirrored(feedURL: feedURL)
    }

    /// Un-hide re-admits the channel; the next mirror pass re-subscribes it
    /// (server = source of truth), so the caller kicks one.
    static func unhide(feedURL: String) {
        var set = hiddenFeeds(); set.remove(feedURL)
        UserDefaults.standard.set(Array(set).sorted(), forKey: hiddenKey)
        var titles = UserDefaults.standard.dictionary(forKey: hiddenTitlesKey) as? [String: String] ?? [:]
        titles.removeValue(forKey: feedURL)
        UserDefaults.standard.set(titles, forKey: hiddenTitlesKey)
    }

    /// One mirror pass. Returns the mirrored-group size on success.
    @discardableResult
    static func mirror() async throws -> Int {
        // The switch acts HERE. Off means no requests, not merely a hidden
        // surface, the same line as with every other source.
        guard AppStorageKeys.pinchflatActive else { return 0 }
        guard let host = PinchflatClient.serverURL?.host else { return 0 }
        let serverFeeds = try await PinchflatClient.fetchFeedURLs()
        let tag = PinchflatMirror.originTag(host: host)
        let subs = PodcastSubscriptions.shared
        await subs.ensureLoaded()
        let mirrored = Set(subs.shows.filter { $0.origin == tag }.map(\.feedURL))
        let diff = PinchflatMirror.diff(serverFeeds: serverFeeds,
                                        mirrored: mirrored, hidden: hiddenFeeds())
        let login = PinchflatClient.credentials(host: host)
        for feedURL in diff.toSubscribe {
            // The feeds authenticate via Basic Auth (verified at the stand).
            // Each mirrored feed INHERITS the server login before the fetch.
            if let login {
                PodcastFeedAuth.set(feedKey: PodcastSubscriptions.feedKey(feedURL),
                                    user: login.user, password: login.password)
            }
            // A mirror is mechanics: it never notes a travelling choice.
            if await subs.subscribe(urlString: feedURL, notesCloud: false) {
                subs.setOrigin(tag, forFeedURL: feedURL)
            }
        }
        for feedURL in diff.toUnsubscribe {
            // Progress stays. The row simply leaves the group. Server-driven,
            // so NOT the user-unsubscribe (gpodder user-intent stays clean).
            subs.removeMirrored(feedURL: feedURL)
        }
        Logger.rss.notice("PINCHFLAT mirror host=\(host, privacy: .public) +\(diff.toSubscribe.count) -\(diff.toUnsubscribe.count)")
        return mirrored.count + diff.toSubscribe.count - diff.toUnsubscribe.count
    }

    /// App-start pass: once per session, SILENT on every failure.
    static func mirrorSilentlyOnce() async {
        guard AppStorageKeys.pinchflatActive else { return }
        guard !didRunThisSession, PinchflatClient.serverURL != nil else { return }
        didRunThisSession = true
        _ = try? await mirror()
    }
}
