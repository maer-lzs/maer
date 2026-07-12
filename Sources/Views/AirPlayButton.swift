import SwiftUI
import AVKit

/// AirPlay picker button. Opens the system menu to choose output devices
/// (HomePod, Bluetooth headphones, Apple TV …).
struct AirPlayButton: UIViewRepresentable {
    var tintColor: UIColor = .white
    /// Color when a route is CURRENTLY actively connected (e.g. headphones).
    /// Identical to `tintColor` by default — otherwise orange would flash
    /// unintentionally as soon as any output device is active.
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
