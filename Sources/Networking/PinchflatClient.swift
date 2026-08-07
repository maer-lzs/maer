// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Pinchflat Paket A (5c8ff27/a404b38): the SERVER is the source of the FEED
/// LIST, not a new playback provider — its per-channel feeds are plain RSS
/// and ride the existing `rss:` path (no new namespace, no router entry; the
/// architecture decision is fixed and verified at the Pinchflat source).
///
/// What the server contributes: (a) the list (`/sources/opml` instead of
/// hand-adding channels) and (b) the provenance per feed.
///
/// Hard rules (#106 lesson): the `route_token` lives in the KEYCHAIN and is
/// NEVER logged — log lines carry the host only, never a URL with the token
/// query. Verified at the live test stand: the OPML's xmlUrls come WITHOUT
/// the token; the feeds themselves authenticate via Basic Auth.
@MainActor
enum PinchflatClient {
    // MARK: - Keychain (host-scoped)

    private static func tokenKey(_ host: String) -> String { "pinchflat.routeToken.\(host)" }
    private static func loginKey(_ host: String) -> String { "pinchflat.login.\(host)" }
    private static let serverDefaultsKey = "pinchflatServerURL"

    /// The configured server base URL (UserDefaults — it is an address, not a
    /// secret; the secrets live in the keychain).
    static var serverURL: URL? {
        get { UserDefaults.standard.string(forKey: serverDefaultsKey).flatMap(URL.init) }
    }

    static func setServer(url: URL?, routeToken: String?, user: String?, password: String?) {
        if let url, let host = url.host {
            UserDefaults.standard.set(url.absoluteString, forKey: serverDefaultsKey)
            if let routeToken, !routeToken.isEmpty {
                KeychainStore.save(routeToken, forKey: tokenKey(host))
            }
            if let user, let password, !user.isEmpty {
                KeychainStore.save("\(user)\n\(password)", forKey: loginKey(host))
            }
        } else if let old = serverURL?.host {
            KeychainStore.delete(forKey: tokenKey(old))
            KeychainStore.delete(forKey: loginKey(old))
            UserDefaults.standard.removeObject(forKey: serverDefaultsKey)
        }
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
        /// 401 — token or login wrong. Its own case so the surface can say so.
        case unauthorized
        /// Anything transport-shaped. For a mesh-only server this is a NORMAL
        /// state (unterwegs), not an app defect — surfaces word it that way.
        case unreachable
        case badAnswer
    }

    /// The channel list. Verified shape: `<outline type="rss" text="…"
    /// xmlUrl="https://host/sources/<uuid>/feed.xml" />` — parsed by the ONE
    /// existing OPML parser (Regel 2).
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
            // Host only — never the URL (it carries the token query).
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


/// Paket A: the mirror run — connect = done, server = source of truth.
/// a404b38 precision: the APP-START mirror fails SILENTLY (a mesh-only
/// server being away is normal); visible errors belong to the manual
/// gesture (connect / refresh) only.
@MainActor
enum PinchflatSync {
    private static let hiddenKey = "pinchflatHiddenFeeds"
    private static var didRunThisSession = false

    static func hiddenFeeds() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
    }

    /// The opt-out exception (a7fa35e): hidden survives mirror runs.
    static func hide(feedURL: String) {
        var set = hiddenFeeds(); set.insert(feedURL)
        UserDefaults.standard.set(Array(set).sorted(), forKey: hiddenKey)
        PodcastSubscriptions.shared.removeMirrored(feedURL: feedURL)
    }

    static func unhide(feedURL: String) {
        var set = hiddenFeeds(); set.remove(feedURL)
        UserDefaults.standard.set(Array(set).sorted(), forKey: hiddenKey)
    }

    /// One mirror pass. Returns the mirrored-group size on success.
    @discardableResult
    static func mirror() async throws -> Int {
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
            // The feeds authenticate via Basic Auth (verified at the stand) —
            // each mirrored feed INHERITS the server login before the fetch.
            if let login {
                PodcastFeedAuth.set(feedKey: PodcastSubscriptions.feedKey(feedURL),
                                    user: login.user, password: login.password)
            }
            if await subs.subscribe(urlString: feedURL) {
                subs.setOrigin(tag, forFeedURL: feedURL)
            }
        }
        for feedURL in diff.toUnsubscribe {
            // Progress stays — the row simply leaves the group. Server-driven,
            // so NOT the user-unsubscribe (gpodder user-intent stays clean).
            subs.removeMirrored(feedURL: feedURL)
        }
        Logger.rss.notice("PINCHFLAT mirror host=\(host, privacy: .public) +\(diff.toSubscribe.count) -\(diff.toUnsubscribe.count)")
        return mirrored.count + diff.toSubscribe.count - diff.toUnsubscribe.count
    }

    /// App-start pass: once per session, SILENT on every failure.
    static func mirrorSilentlyOnce() async {
        guard !didRunThisSession, PinchflatClient.serverURL != nil else { return }
        didRunThisSession = true
        _ = try? await mirror()
    }
}
