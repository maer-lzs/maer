import Foundation

/// Whether an error is *transient* — i.e. a retry makes sense (brief server
/// hang, lost connection, 5xx/429). Deliberately narrower than
/// `NetworkStatus.isOfflineError`: real "no network" errors (no internet, DNS)
/// are NOT retried — there the offline/cache fallback is immediately right.
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
/// rethrowing. Final errors (offline, 401, decoding) throw immediately — the
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

/// Y33 (pure, tested): per-attempt decision for one HTTP request. A 401 gets
/// exactly ONE probe retry before it counts as a real auth failure — gateways
/// answer 401/5xx spuriously during outages, and logging the user out on the
/// first one made a server hiccup cost a re-login. Transient failures back
/// off twice; everything else fails immediately.
nonisolated enum RequestRetryPolicy {
    enum Decision: Equatable {
        case retry(afterMs: Int)
        case fail
    }

    static let transientBackoffMs = [400, 1200]

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
