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
