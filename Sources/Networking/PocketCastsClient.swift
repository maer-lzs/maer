// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

enum PocketCastsError: Error, LocalizedError {
    case loginRejected
    case unreachable
    /// The interface answered, but not in the measured form. Named by the
    /// door, so a report says where it changed.
    case changed(String)

    var errorDescription: String? {
        switch self {
        case .loginRejected: String(localized: "Pocket Casts rejected the sign-in. Signed in with Apple or Google? Set a password on pocketcasts.com under “Forgot password” first.")
        case .unreachable: String(localized: "Pocket Casts is not reachable.")
        case .changed(let door): String(localized: "Pocket Casts has changed its interface (\(door)).")
        }
    }
}

/// One pass over a Pocket Casts account: sign in, list the subscriptions,
/// resolve their feeds, read the listening states and the episode
/// details, hand back the library. Nothing is stored: the credentials
/// live in this call, the token dies with it. Only the person's own
/// account is read, and only when they tap.
nonisolated enum PocketCastsClient {
    static let apiHost = "api.pocketcasts.com"
    static let refreshHost = "refresh.pocketcasts.com"
    static let cacheHost = "cache.pocketcasts.com"

    static func readLibrary(email: String, password: String,
                            progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> ForeignLibrary {
        let token = try await signIn(email: email, password: password)
        return try await readLibrary(token: token, progress: progress)
    }

    /// The read behind any sign-in. The password door above is one way
    /// to a token; a session token from Pocket Casts' own sign-in flow
    /// would be another and needs nothing below this line changed.
    static func readLibrary(token: String,
                            progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> ForeignLibrary {
        let listData = try await post("https://\(apiHost)/user/podcast/list", json: ["v": 1], token: token, door: "list")
        guard let podcasts = PocketCastsAPI.podcasts(from: listData) else { throw PocketCastsError.changed("list") }
        let feedsData = try await post("https://\(refreshHost)/import/export_feed_urls",
                                       json: ["uuids": podcasts.map(\.uuid)], token: nil, door: "feeds")
        guard let feeds = PocketCastsAPI.feedURLs(from: feedsData) else { throw PocketCastsError.changed("feeds") }

        var states: [String: [PocketCastsAPI.EpisodeState]] = [:]
        var episodes: [String: [PocketCastsAPI.CachedEpisode]] = [:]
        for (index, podcast) in podcasts.enumerated() {
            progress(index + 1, podcasts.count)
            guard feeds[podcast.uuid] != nil else { continue }
            let stateData = try await post("https://\(apiHost)/user/podcast/episodes",
                                           json: ["uuid": podcast.uuid], token: token, door: "episodes")
            guard let rows = PocketCastsAPI.episodeStates(from: stateData) else { throw PocketCastsError.changed("episodes") }
            let listened = rows.filter { $0.finished || $0.inProgress }
            guard !listened.isEmpty else { continue }
            states[podcast.uuid] = listened
            // The cache knows title and enclosure; a podcast it does not
            // carry still yields states, which then match by nothing and
            // are named as unmatched.
            let cacheData = try await get("https://\(cacheHost)/podcast/full/\(podcast.uuid)", door: "cache")
            let cached = PocketCastsAPI.cachedPodcast(from: cacheData)
            episodes[podcast.uuid] = cached?.episodes ?? []
            // The cache answers per show id. Hold its name against the
            // account list and count what it carries against the states:
            // a cache that names another show, or carries fewer episodes
            // than the account has states for, explains states whose
            // titles belong to nothing the person has. Hashed ids, titles
            // private.
            let listTitle = podcast.title ?? ""
            let cacheTitle = cached?.title ?? ""
            let known = Set(cached?.episodes.map(\.uuid) ?? [])
            let withoutCache = listened.filter { !known.contains($0.uuid) }.count
            Logger.rss.notice("FOREIGN cache show=\(PodcastSubscriptions.stableHash(podcast.uuid), privacy: .public) states=\(listened.count) cached=\(known.count) statesWithoutCache=\(withoutCache) cacheTitle=\(cacheTitle.isEmpty ? "none" : "present", privacy: .public)")
            if !listTitle.isEmpty, !cacheTitle.isEmpty,
               listTitle.compare(cacheTitle, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame {
                Logger.rss.warning("FOREIGN cache-mismatch show=\(PodcastSubscriptions.stableHash(podcast.uuid), privacy: .public) list=\(listTitle, privacy: .private) cache=\(cacheTitle, privacy: .private)")
            }
        }
        let library = PocketCastsAPI.library(podcasts: podcasts, feedURLs: feeds, states: states, episodes: episodes)
        Logger.rss.notice("POCKETCASTS read: podcasts=\(podcasts.count) feeds=\(feeds.count) states=\(library.states.count)")
        return library
    }

    private static func signIn(email: String, password: String) async throws -> String {
        let data: Data
        let status: Int
        do {
            (data, status) = try await send(request("https://\(apiHost)/user/login",
                                                    json: ["email": email, "password": password, "scope": "webplayer"],
                                                    token: nil))
        } catch {
            throw PocketCastsError.unreachable
        }
        if status == 401 || status == 403 { throw PocketCastsError.loginRejected }
        guard (200...299).contains(status) else { throw PocketCastsError.changed("login \(status)") }
        guard let token = PocketCastsAPI.token(from: data) else { throw PocketCastsError.changed("login") }
        return token
    }

    private static func post(_ url: String, json: [String: Any], token: String?, door: String) async throws -> Data {
        let (data, status) = try await sendOrUnreachable(request(url, json: json, token: token))
        guard (200...299).contains(status) else { throw PocketCastsError.changed("\(door) \(status)") }
        return data
    }

    private static func get(_ url: String, door: String) async throws -> Data {
        guard let target = URL(string: url) else { throw PocketCastsError.changed(door) }
        var request = URLRequest(url: target)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, status) = try await sendOrUnreachable(request)
        guard (200...299).contains(status) else { throw PocketCastsError.changed("\(door) \(status)") }
        return data
    }

    private static func request(_ url: String, json: [String: Any], token: String?) throws -> URLRequest {
        guard let target = URL(string: url) else { throw PocketCastsError.changed("url") }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return request
    }

    private static func sendOrUnreachable(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            return try await send(request)
        } catch {
            Logger.rss.error("POCKETCASTS unreachable: \(request.url?.host ?? "?", privacy: .public)")
            throw PocketCastsError.unreachable
        }
    }

    /// The last response with its status; a URL-level failure throws.
    private static func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await RequestRetryPolicy.fetch(request)
        return (data, response?.statusCode ?? 0)
    }
}
