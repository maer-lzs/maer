// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import AVKit

/// AirPlay picker button. Opens the system menu to choose output devices
/// (HomePod, Bluetooth headphones, Apple TV …).
struct AirPlayButton: UIViewRepresentable {
    var tintColor: UIColor = .white
    /// Color when a route is CURRENTLY actively connected (e.g. headphones).
    /// Identical to `tintColor` by default. Otherwise orange would flash
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

/// Whether the sound goes to an output away from the device: AirPlay,
/// Bluetooth, the car, a screen. The device's speaker, receiver and wired
/// headphones are its own. The mini player marks such a route in the
/// accent colour, as the picker's active tint did.
enum AudioRouteRule {
    static let external: Set<AVAudioSession.Port> = [
        .airPlay, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .carAudio, .HDMI, .usbAudio,
    ]

    static func isExternal(_ outputs: [AVAudioSession.Port]) -> Bool {
        outputs.contains(where: external.contains)
    }

    /// The outputs of the route the session plays to now.
    static var current: Bool {
        isExternal(AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType))
    }
}
