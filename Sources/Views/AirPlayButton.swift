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
