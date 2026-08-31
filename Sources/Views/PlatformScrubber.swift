// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import UIKit

/// Where the app runs, as far as the SLIDER question is concerned.
///
/// The iOS app on an Apple-silicon Mac crashes the moment SwiftUI's
/// `Slider` builds its fluid-slider haptics: six crash reports, two app
/// versions, byte-identical in Apple's own
/// `_UIFluidSliderFeedbackConfiguration defaultConfiguration`, with no
/// app frame in the stack. It is an OS defect, and macOS 27 goes final
/// in September, so waiting is not a plan.
///
/// Pure and injectable, because a runtime idiom is otherwise untestable
/// and the red probe has to show that the branch is Mac-only.
nonisolated enum PlatformIdiom {
    /// True only for the iOS app running on macOS. iPad idiom on real
    /// iPads stays false; that path must keep the system slider.
    static var isAppOnMac: Bool {
        ProcessInfo.processInfo.isiOSAppOnMac
            || ProcessInfo.processInfo.isMacCatalystApp
    }

    /// The decision as a pure rule: only the Mac case avoids the system
    /// slider, everything else keeps it.
    static func avoidsSystemSlider(isAppOnMac: Bool) -> Bool { isAppOnMac }
}

/// The scrubber the player shows. On iOS/iPadOS it IS the system
/// `Slider` (unchanged behaviour, unchanged look). On the Mac it is a
/// track the app draws itself and drags with a plain gesture, so the
/// crashing haptics configuration is never built.
///
/// The Mac form deliberately keeps the same geometry (track height,
/// thumb size, tap-anywhere-to-seek) rather than inventing a second
/// visual language: what differs is who owns the gesture, not what the
/// player looks like.
struct PlatformScrubber: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Same contract as `Slider(onEditingChanged:)`: true when a drag
    /// begins, false when it ends (the caller seeks on false).
    let onEditingChanged: (Bool) -> Void
    /// Injectable for the red probe; production reads the runtime.
    var isAppOnMac: Bool = PlatformIdiom.isAppOnMac

    @State private var dragging = false

    var body: some View {
        if PlatformIdiom.avoidsSystemSlider(isAppOnMac: isAppOnMac) {
            macTrack
        } else {
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
        }
    }

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    private var macTrack: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: 4)
                Capsule().fill(.white.opacity(0.85))
                    .frame(width: width * fraction, height: 4)
                Circle().fill(.white)
                    .frame(width: dragging ? 18 : 14, height: dragging ? 18 : 14)
                    .offset(x: width * fraction - (dragging ? 9 : 7))
            }
            .frame(height: 28)
            .contentShape(Rectangle())
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
        .frame(height: 28)
    }

    private func position(of x: CGFloat, width: CGFloat) -> Double {
        let share = min(max(Double(x / width), 0), 1)
        return range.lowerBound + share * (range.upperBound - range.lowerBound)
    }
}
