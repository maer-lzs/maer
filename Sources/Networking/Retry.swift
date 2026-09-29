// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Synchronization

/// Whether an error is *transient*. I.e. a retry makes sense (brief server
/// hang, lost connection, 5xx/429). Deliberately narrower than
/// `NetworkStatus.isOfflineError`: real "no network" errors (no internet, DNS)
/// are NOT retried. There the offline/cache fallback is immediately right.
/// 401 (auth) and decoding errors are also treated as final.
func isTransientError(_ error: Error) -> Bool {
    if let api = error as? APIError, case .http(let code, _) = api {
        return code == 429 || (500...599).contains(code)
    }
    let ns = error as NSError
    guard ns.domain == NSURLErrorDomain else { return false }
    let transientCodes: Set<Int> = [
        NSURLErrorTimedOut,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorCannotConnectToHost,
    ]
    return transientCodes.contains(ns.code)
}

/// Runs `op` and retries transient errors with a short backoff before
/// rethrowing. Final errors (offline, 401, decoding) throw immediately. The
/// caller then decides about the cache fallback.
func withRetry<T>(attempts: Int = 3,
                  backoff: [Double] = [0.4, 1.2],
                  _ op: () async throws -> T) async throws -> T {
    var lastError: Error?
    for attempt in 0..<max(1, attempts) {
        do {
            return try await op()
        } catch {
            lastError = error
            guard isTransientError(error), attempt < attempts - 1 else { throw error }
            let delay = attempt < backoff.count ? backoff[attempt] : (backoff.last ?? 1.0)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
    throw lastError ?? APIError.invalidResponse
}

/// Pure and tested: per-attempt decision for one HTTP request. A 401 gets
/// exactly ONE probe retry before it counts as a real auth failure. Gateways
/// answer 401/5xx spuriously during outages, and logging the user out on the
/// first one made a server hiccup cost a re-login. Transient failures back
/// off twice; everything else fails immediately.
nonisolated enum RequestRetryPolicy {
    enum Decision: Equatable {
        case retry(afterMs: Int)
        case fail
    }

    static let transientBackoffMs = [400, 1200]

    /// Subsonic reports auth failures as an API code INSIDE a 200
    /// envelope (40 = wrong credentials, 41 = token auth unsupported). Map
    /// them onto the 401 probe so a gateway hiccup doesn't read as "wrong
    /// password". Every other API code is final.
    static func subsonicDecision(apiCode: Int, attempt: Int) -> Decision {
        (apiCode == 40 || apiCode == 41)
            ? decide(status: 401, urlErrorCode: nil, attempt: attempt)
            : .fail
    }

    /// One policy-driven fetch loop for the NON-ABS clients (Subsonic
    /// envelope requests, RSS feed pulls). The ABS `APIClient.perform` runs
    /// the same policy with its own logout hook. Returns the LAST response
    /// (even non-2xx) so the caller keeps its own status semantics; URL-level
    /// errors rethrow after the policy gives up. `once` asks exactly one
    /// time: a bulk run over many feeds names a feed that does not answer
    /// instead of waiting a whole ladder for it.
    static func fetch(_ request: URLRequest,
                      session: URLSession? = nil,
                      redirects: RedirectGuard? = nil,
                      once: Bool = false) async throws -> (Data, HTTPURLResponse?) {
        // Default argument can't reference `.maer` here (isolation of the
        // default-value context). Resolve inside instead.
        let session = session ?? URLSession.maer
        // Most foreign services are asked straight from here, past
        // `HTTP.prepare`, so the identity is set here as well.
        var request = request
        AppUserAgent.applyIfMissing(to: &request)
        // Past every rung of `decide`, the first answer is final.
        var attempt = once ? Int.max : 0
        var pauseMs: Int?
        var lastAnswer: (Data, HTTPURLResponse?)?
        while true {
            if let pauseMs {
                // bearable, because a cancelled pause ends in the courtesy gate or the request right after
                try? await Task.sleep(nanoseconds: UInt64(pauseMs) * 1_000_000)
            }
            // Every attempt passes the courtesy gate: a host that asked to
            // rest is waited for there, or the request ends unsent. A retry
            // that meets a long rest hands back the answer that asked for
            // it, so the caller reads the status as before.
            let answered: (Data, HTTPURLResponse?)
            do {
                let (data, response) = try await courteously(request) {
                    try await session.data(for: request, delegate: redirects)
                }
                answered = (data, response as? HTTPURLResponse)
            } catch let resting as HostCourtesy.Resting {
                if let lastAnswer { return lastAnswer }
                throw resting
            } catch let urlError as URLError {
                if case .retry(let ms) = decide(status: nil, urlErrorCode: urlError.code.rawValue,
                                                attempt: attempt) {
                    attempt += 1
                    pauseMs = ms
                    continue
                }
                throw urlError
            }
            let http = answered.1
            if let status = http?.statusCode, !(200...299).contains(status),
               case .retry(let ms) = decide(status: status, urlErrorCode: nil, attempt: attempt) {
                attempt += 1
                pauseMs = ms
                lastAnswer = answered
                continue
            }
            return answered
        }
    }

    /// The courtesy gate around ONE question: `HostCourtesy` is entered
    /// before the request and left with its answer, whatever the outcome.
    /// Every way out passes here: `fetch` per attempt, and the ways of the
    /// HTTP door that ask their session once.
    static func courteously<Value>(_ request: URLRequest,
                                   _ ask: () async throws -> (Value, URLResponse)) async throws -> (Value, URLResponse) {
        let courtesy = HostCourtesy.shared
        let pass = try await courtesy.enter(request.url)
        do {
            let answer = try await ask()
            let http = answer.1 as? HTTPURLResponse
            await courtesy.leave(pass, status: http?.statusCode,
                                 retryAfter: http?.value(forHTTPHeaderField: "Retry-After"))
            return answer
        } catch {
            await courtesy.leave(pass, status: nil, retryAfter: nil,
                                 refused: HostCourtesyRule.isRefusal(error))
            throw error
        }
    }

    static func decide(status: Int?, urlErrorCode: Int?, attempt: Int) -> Decision {
        if status == 401 {
            return attempt == 0 ? .retry(afterMs: 500) : .fail
        }
        let transientStatus = status.map { $0 == 429 || (500...599).contains($0) } ?? false
        let transientURLError = urlErrorCode.map {
            [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotConnectToHost].contains($0)
        } ?? false
        if transientStatus || transientURLError {
            return attempt < transientBackoffMs.count
                ? .retry(afterMs: transientBackoffMs[attempt])
                : .fail
        }
        return .fail
    }
}

/// Follows a redirect only to an address `allows` accepts. A request whose
/// query carries a credential in clear text (the Subsonic key) must not be
/// handed to an unencrypted target by a redirect it never chose. A refused
/// redirect ends the request with the 3xx answer, and `refused` says so, so
/// the caller can name the reason instead of a status.
nonisolated final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    private let allows: @Sendable (URL) -> Bool
    private let refusals = Mutex(0)

    init(allows: @escaping @Sendable (URL) -> Bool) { self.allows = allows }

    var refused: Bool { refusals.withLock { $0 > 0 } }

    // The completion-handler form on purpose: the async form of this
    // delegate method crashes the compiler (Swift 6.4) while it builds the
    // Objective-C thunk.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let target = request.url, allows(target) else {
            refusals.withLock { $0 += 1 }
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
