import SwiftUI
import AVKit

/// AirPlay-Auswahlbutton. Öffnet das System-Menü zur Auswahl von
/// Ausgabegeräten (HomePod, Bluetooth-Kopfhörer, Apple TV …).
struct AirPlayButton: UIViewRepresentable {
    var tintColor: UIColor = .white

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = tintColor
        view.activeTintColor = UIColor(AppTheme.accent)
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tintColor
    }
}
