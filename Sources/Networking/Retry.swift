import Foundation

/// Ob ein Fehler *transient* ist — also ein Wiederholungsversuch Sinn ergibt
/// (kurzer Server-Hänger, verlorene Verbindung, 5xx/429). Bewusst enger als
/// `NetworkStatus.isOfflineError`: echte „kein Netz"-Fehler (kein Internet, DNS)
/// werden NICHT wiederholt — dort ist sofort der Offline-/Cache-Fallback richtig.
/// 401 (Auth) und Decoding-Fehler gelten ebenfalls als endgültig.
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

/// Führt `op` aus und wiederholt bei transienten Fehlern mit kurzem Backoff,
/// bevor der Fehler durchgereicht wird. Endgültige Fehler (Offline, 401,
/// Decoding) werfen sofort — der Aufrufer entscheidet dann über Cache-Fallback.
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
