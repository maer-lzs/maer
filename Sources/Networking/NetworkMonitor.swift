// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import Network
import OSLog

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

    /// The path as a word: its status and the kinds of interface it offers.
    /// Nil until the first path arrived, which is the baseline, not a change.
    private var pathSignature: String?
    private var changeHandlers: [@MainActor () -> Void] = []

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let signature = "\(path.status)|" + path.availableInterfaces.map { "\($0.type)" }.joined(separator: ",")
            Task { @MainActor [weak self] in
                self?.isConnected = connected
                self?.took(pathSignature: signature)
            }
        }
        // queue because NWPathMonitor starts on a DispatchQueue; the handler hops into a Task at once.
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    private func took(pathSignature signature: String) {
        defer { pathSignature = signature }
        guard let previous = pathSignature, previous != signature else { return }
        Logger.library.notice("NETWORK path changed \(previous, privacy: .public) -> \(signature, privacy: .public)")
        for handler in changeHandlers { handler() }
    }
}

extension NetworkMonitor: MaerSyncPathSource {
    func onChange(_ handler: @escaping @MainActor () -> Void) {
        changeHandlers.append(handler)
    }
}
