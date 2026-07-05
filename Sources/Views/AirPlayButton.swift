import SwiftUI
import AVKit

/// AirPlay-Auswahlbutton. Öffnet das System-Menü zur Auswahl von
/// Ausgabegeräten (HomePod, Bluetooth-Kopfhörer, Apple TV …).
struct AirPlayButton: UIViewRepresentable {
    var tintColor: UIColor = .white
    /// Farbe, wenn GERADE eine Route aktiv verbunden ist (z. B. Kopfhörer).
    /// Standardmäßig identisch mit `tintColor` — sonst würde ungewollt Orange
    /// aufblitzen, sobald irgendein Ausgabegerät aktiv ist.
    var activeTintColor: UIColor? = nil

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = tintColor
        view.activeTintColor = activeTintColor ?? tintColor
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tintColor
        uiView.activeTintColor = activeTintColor ?? tintColor
    }
}
