// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Network

/// One-shot snapshot check whether Wi-Fi is currently available. Not a
/// continuous monitor, just a brief snapshot before a download.
enum NetworkStatus {
    /// Guards against resolving the continuation twice if the path handler
    /// fires more than once before the monitor is cancelled. An actor rather
    /// than lock+flag so access stays cleanly isolated under Swift 6
    /// concurrency checking.
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
            // queue because NWPathMonitor starts on a DispatchQueue; the handler hops into a Task at once.
            monitor.start(queue: DispatchQueue.global(qos: .utility))
        }
    }

    /// Detects pure network unreachability (no net, timeout, DNS failure …).
    /// As opposed to real errors like 401 or a broken server format, which must
    /// NOT be mistaken for "offline". The set lives in `NetworkReach` (Models),
    /// so player, library and the error sentence share one definition.
    static func isOfflineError(_ error: Error) -> Bool {
        NetworkReach.isOffline(error as NSError)
    }
}
