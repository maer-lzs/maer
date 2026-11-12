// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// THE door for every network request of the app (a fence keeps
/// `URLSession` out of the rest). One place for what every request needs:
/// the app's one identity (User-Agent), the retry policy, the cleartext
/// upgrade for addresses that must be https, the timeouts of the lane, and
/// a log line with the reason for every failure, host only, never a URL
/// with a token in it.
///
/// Lanes are the few shapes of traffic the app has; a caller names the lane
/// and hands over the request, nothing else.
nonisolated enum HTTP {
    enum Lane: String, Sendable {
        /// Server APIs and catalogue clients: 20 s per request.
        case api
        /// Podcast feeds: the address is raised to https before the request.
        case feed
        /// Cover bytes: no URLCache (ImageCache owns caching), https raised.
        case cover
        /// Mass routes that compute (catalogue stock, gutendex): 120 s.
        case mass
        /// Uploads (the importer's book): only the wait without movement
        /// bounds them, never a total, which a large book outlasts.
        case upload
        /// Live streams and HEAD checks on streams: 10 s, no retry.
        case stream
        /// gpodder: cookies for the session-based servers.
        case cookies
        /// A socket that stays open and idle for as long as the service
        /// has nothing to announce.
        case socket
    }

    /// The session of a lane. Sessions are built once (`URLSession+Maer`).
    static func session(_ lane: Lane) -> URLSession {
        switch lane {
        case .api, .feed, .stream: return .maer
        case .cover: return .coverImage
        case .mass: return .mass
        case .upload: return .upload
        case .cookies: return .cookies
        case .socket: return .socket
        }
    }

    /// How long the app waits for a service to answer the socket upgrade.
    /// The standing connection is NOT governed by it (measured); a service
    /// that leaves the upgrade open is the case this catches.
    static let socketUpgradeTimeout: TimeInterval = 60

    /// A socket on the socket lane; the caller resumes, receives and
    /// cancels the task. Handed out here so the session stays behind the
    /// door like every other one.
    static func webSocket(for request: URLRequest) throws -> URLSessionWebSocketTask {
        var out = prepare(request, lane: .socket)
        try ServerHeaders.admit(out)
        // MEASURED, because the answer is the opposite of what it looks
        // like: on a socket task this value is the deadline of the UPGRADE,
        // not of the standing connection. A silent open socket stood 95
        // seconds with 60 here and 25 seconds with 5 here; an upgrade that
        // was never answered failed after exactly 5 seconds with `-1001`.
        // So it stays SHORT, and raising it to the session's hour would buy
        // nothing for the idle case and make a hung upgrade wait an hour.
        // It is written here, at the one door, because the value on the
        // request beats the session's and a hand-built request carries
        // URLRequest's own default silently.
        out.timeoutInterval = socketUpgradeTimeout
        let task = session(.socket).webSocketTask(with: out)
        task.delegate = RedirectGuard.following()
        return task
    }

    /// A request with data and the HTTP response. Retries by the policy
    /// (401 once, 429 and 5xx twice, transient URL errors twice); on the
    /// stream lane never, and not for a caller that runs a loop of its own
    /// (`retry: false`). A failure is logged with its reason and rethrown.
    static func data(for request: URLRequest, lane: Lane = .api,
                     retry: Bool = true, repeatable: Bool = true) async throws -> (Data, HTTPURLResponse?) {
        let prepared = prepare(request, lane: lane)
        do {
            try ServerHeaders.admit(prepared)
            if lane == .stream || !retry {
                let (data, response) = try await courteously(prepared) {
                    try await session(lane).data(for: prepared, delegate: RedirectGuard.following())
                }
                return (data, response as? HTTPURLResponse)
            }
            return try await RequestRetryPolicy.fetch(prepared, session: session(lane), repeatable: repeatable)
        } catch {
            log(failure: error, request: prepared, lane: lane)
            throw error
        }
    }

    static func data(from url: URL, lane: Lane = .api) async throws -> (Data, HTTPURLResponse?) {
        try await data(for: URLRequest(url: url), lane: lane)
    }

    /// A stream opened for its headers (the radio check): no retry, and
    /// the caller cancels the task once it has what it wanted.
    static func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        let prepared = prepare(request, lane: .stream)
        do {
            try ServerHeaders.admit(prepared)
            return try await courteously(prepared) {
                try await session(.stream).bytes(for: prepared, delegate: RedirectGuard.following())
            }
        } catch {
            log(failure: error, request: prepared, lane: .stream)
            throw error
        }
    }

    /// A file downloaded to a temporary location (the importer).
    static func download(from url: URL, lane: Lane = .api) async throws -> (URL, URLResponse) {
        let prepared = prepare(URLRequest(url: url), lane: lane)
        do {
            try ServerHeaders.admit(prepared)
            return try await courteously(prepared) {
                try await session(lane).download(for: prepared, delegate: RedirectGuard.following())
            }
        } catch {
            log(failure: error, request: prepared, lane: lane)
            throw error
        }
    }

    /// An upload from a file (the importer's multipart body).
    static func upload(for request: URLRequest, fromFile file: URL, lane: Lane = .upload) async throws -> (Data, HTTPURLResponse?) {
        let prepared = prepare(request, lane: lane)
        do {
            try ServerHeaders.admit(prepared)
            let (data, response) = try await courteously(prepared) {
                try await session(lane).upload(for: prepared, fromFile: file, delegate: RedirectGuard.following())
            }
            return (data, response as? HTTPURLResponse)
        } catch {
            log(failure: error, request: prepared, lane: lane)
            throw error
        }
    }

    /// The session of one sign-in flow: the start of the flow and the
    /// exchange of its code ride on it, so the cookie the server ties the
    /// two together with lives only as long as the flow (`close`). A request
    /// on it follows no redirect and gets the server's headers and the
    /// courtesy gate like every request; it is asked once, a flow repeats
    /// as a whole.
    nonisolated final class SignInFlow: Sendable {
        private let session = URLSession.signInFlow()

        /// Whether the flow's cookies stay apart from the shared store.
        var keepsCookiesApart: Bool {
            guard let own = session.configuration.httpCookieStorage else { return true }
            return own !== HTTPCookieStorage.shared
        }

        /// The flow's own cookie store; nil when the session keeps none.
        var cookieStorage: HTTPCookieStorage? { session.configuration.httpCookieStorage }

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let prepared = HTTP.prepare(request, lane: .api)
            do {
                try ServerHeaders.admit(prepared)
                let (data, response) = try await HTTP.courteously(prepared) {
                    try await session.data(for: prepared, delegate: RedirectGuard.followingNone())
                }
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                return (data, http)
            } catch {
                HTTP.log(failure: error, request: prepared, lane: .api)
                throw error
            }
        }

        /// Ends the flow: its cookies go with the session.
        func close() {
            session.invalidateAndCancel()
        }
    }

    /// The ways that ask their session once pass the same courtesy gate as
    /// each attempt of the retrying way.
    private static func courteously<Value>(_ request: URLRequest,
                                           _ ask: () async throws -> (Value, URLResponse)) async throws -> (Value, URLResponse) {
        try await RequestRetryPolicy.courteously(request, ask)
    }

    // MARK: - What every request gets

    /// The identity, the headers of the request's server, and the https
    /// upgrade where the lane needs it.
    static func prepare(_ request: URLRequest, lane: Lane) -> URLRequest {
        var out = request
        AppUserAgent.applyIfMissing(to: &out)
        if lane == .feed || lane == .cover, let url = out.url {
            out.url = PodcastFeedAddress.upgraded(url)
        }
        // After the upgrade: the headers belong to the address that is asked.
        ServerHeaders.apply(to: &out)
        return out
    }

    /// The reason in the log, host only.
    static func log(failure error: Error, request: URLRequest, lane: Lane) {
        guard !error.isCancellation else { return }
        let host = request.url?.host ?? "-"
        let reason = FailureReason.of(error)
        Logger.library.notice("HTTP fail lane=\(lane.rawValue, privacy: .public) host=\(host, privacy: .public) reason=\(reason, privacy: .public)")
    }
}
