import Foundation
import Network

/// Einmaliger Snapshot-Check, ob aktuell WLAN verfügbar ist — kein
/// dauerhafter Monitor, nur eine kurze Momentaufnahme vor dem Download.
enum NetworkStatus {
    /// Schützt vor doppeltem Auflösen der Continuation, falls der
    /// Path-Handler mehrfach feuert, bevor der Monitor gecancelt ist.
    /// Als actor statt Lock+Flag, damit der Zugriff auch unter Swift 6
    /// Concurrency-Checking sauber isoliert ist.
    private actor ResumeGuard {
        private var didResume = false
        func tryResume() -> Bool {
            guard !didResume else { return false }
            didResume = true
            return true
        }
    }

    static func isOnWiFi() async -> Bool {
        let resumeGuard = ResumeGuard()
        return await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                Task {
                    if await resumeGuard.tryResume() {
                        continuation.resume(returning: path.usesInterfaceType(.wifi))
                        monitor.cancel()
                    }
                }
            }
            monitor.start(queue: DispatchQueue.global(qos: .utility))
        }
    }

    /// Erkennt reine Netzwerk-Nichterreichbarkeit (kein Netz, Timeout, DNS
    /// nicht auflösbar …) — im Unterschied zu echten Fehlern wie 401 oder
    /// einem kaputten Server-Format, die NICHT als "offline" missverstanden
    /// werden sollen. Zentral an einer Stelle, damit Player und Bibliothek
    /// exakt dieselbe Definition von "offline" verwenden.
    static func isOfflineError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        let offlineCodes: Set<Int> = [
            NSURLErrorNotConnectedToInternet,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost,
            NSURLErrorCannotFindHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorDataNotAllowed,
            NSURLErrorInternationalRoamingOff
        ]
        return offlineCodes.contains(nsError.code)
    }
}
