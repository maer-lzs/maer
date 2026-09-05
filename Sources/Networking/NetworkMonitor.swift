// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import Network

/// Continuously observes the network status. Unlike `NetworkStatus` (which
/// only takes a one-shot snapshot for the Wi-Fi warning). Used to refresh the
/// library automatically once the connection returns after an offline phase,
/// even when the app stayed in the foreground the whole time (so the scenePhase
/// trigger never fired).
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isConnected = true

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.isConnected = connected
            }
        }
        // queue because NWPathMonitor starts on a DispatchQueue; the handler hops into a Task at once.
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }
}
