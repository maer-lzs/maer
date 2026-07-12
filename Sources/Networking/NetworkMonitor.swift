import Foundation
import Combine
import Network

/// Continuously observes the network status — unlike `NetworkStatus` (which
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
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }
}
