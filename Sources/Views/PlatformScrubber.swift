// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import UIKit

/// Where the app runs: the iOS app on a Mac or not. One place asks the
/// runtime (`DeviceIdentity` names the device by it).
nonisolated enum PlatformIdiom {
    static var isAppOnMac: Bool {
        ProcessInfo.processInfo.isiOSAppOnMac
            || ProcessInfo.processInfo.isMacCatalystApp
    }
}

/// The player's progress bar, one form on every device and in every
/// posture: a bar with round ends and no thumb, the played part bright,
/// the rest muted; it grows while a finger holds it. A drag or a tap
/// anywhere on it seeks. It never builds the system `Slider`, whose
/// haptics configuration crashes the iOS app on a Mac.
struct PlatformScrubber: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Same contract as `Slider(onEditingChanged:)`: true when a drag
    /// begins, false when it ends (the caller seeks on false).
    let onEditingChanged: (Bool) -> Void

    /// The bar's thickness at rest and while held.
    static let restHeight: CGFloat = 7
    static let heldHeight: CGFloat = 12
    /// The area that takes the finger, taller than the bar and as tall as
    /// the system slider's.
    static let hitHeight: CGFloat = 32

    @State private var dragging = false

    /// The arithmetic lives in `ScrubberMath`, pure, so its edges have
    /// witnesses: an empty range, a track of no width, a step at the ceiling.
    private var fraction: Double { ScrubberMath.fraction(of: value, in: range) }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let height = dragging ? Self.heldHeight : Self.restHeight
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white.opacity(dragging ? 1 : 0.85))
                    .frame(width: width * fraction)
            }
            .frame(height: height)
            .clipShape(Capsule())
            .frame(maxHeight: .infinity)
            .animation(.easeOut(duration: 0.15), value: dragging)
            .contentShape(Rectangle())
            // A drawn bar carries no adjustable trait, VoiceOver or keyboard
            // control of its own; they are built here by hand.
            .accessibilityElement()
            .accessibilityLabel(Text("Playback position"))
            .accessibilityValue(Text(accessibilityValueText))
            .accessibilityAdjustableAction { direction in
                value = ScrubberMath.stepped(from: value, in: range,
                                             increasing: direction == .increment)
                onEditingChanged(true)
                onEditingChanged(false)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !dragging { dragging = true; onEditingChanged(true) }
                        value = position(of: drag.location.x, width: width)
                    }
                    .onEnded { drag in
                        value = position(of: drag.location.x, width: width)
                        dragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: Self.hitHeight)
    }

    /// Spoken position: minutes and seconds, never a raw number.
    private var accessibilityValueText: String {
        let seconds = Int(value.rounded())
        let minutes = seconds / 60
        return String(format: "%d:%02d", minutes, seconds % 60)
    }

    private func position(of x: CGFloat, width: CGFloat) -> Double {
        ScrubberMath.value(atX: Double(x), width: Double(width), in: range)
    }
}
