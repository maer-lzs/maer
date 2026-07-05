import Foundation
import Combine
import Network

/// Beobachtet fortlaufend den Netzwerkstatus — anders als `NetworkStatus`
/// (das nur eine einmalige Momentaufnahme für die WLAN-Warnung macht). Wird
/// genutzt, um die Bibliothek automatisch zu aktualisieren, sobald die
/// Verbindung nach einer Offline-Phase zurückkommt, auch wenn die App die
/// ganze Zeit im Vordergrund war (und der scenePhase-Trigger deshalb nie
/// ausgelöst hat).
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
