// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The speed menu of the full player and of the wide playback bar: one menu,
/// two labels (the rate with its symbol, or the symbol alone in the bar).
struct SpeedMenu: View {
    @ObservedObject var viewModel: PlayerViewModel
    var iconOnly = false

    static let rates: [Double] = [0.8, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        Menu {
            // Picker inside a Menu shows a checkmark on the active rate.
            Picker("Speed", selection: Binding(
                get: { Double(viewModel.playbackRate) },
                set: { viewModel.setPlaybackRate(Float($0)) }
            )) {
                ForEach(Self.rates, id: \.self) { rate in
                    Text(Self.label(rate) + "×").tag(rate)
                }
            }
        } label: {
            let changed = viewModel.playbackRate != 1.0
            let text = Self.label(Double(viewModel.playbackRate)) + "×"
            Group {
                if iconOnly {
                    Image(systemName: "speedometer")
                        .accessibilityLabel(Text("Speed \(text)"))
                } else {
                    Label(text, systemImage: "speedometer")
                }
            }
            // Non-default speed is visible at a glance.
            .foregroundStyle(changed ? AnyShapeStyle(AppTheme.accent)
                                     : (iconOnly ? AnyShapeStyle(.primary) : AnyShapeStyle(.white)))
        }
    }

    static func label(_ rate: Double) -> String {
        var text = String(format: "%.2f", rate)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// The sleep timer menu of the full player and of the wide playback bar.
struct SleepTimerMenu: View {
    @ObservedObject var viewModel: PlayerViewModel
    var iconOnly = false
    /// A cell of the side column's capsule: the glyph, and while a timer
    /// runs the number of its remaining minutes small under it.
    var columnCell = false

    static let options: [Double] = [5, 15, 30, 45, 60]

    private var running: Bool { viewModel.sleepTimerRemaining != nil }

    private var label: String {
        guard let remaining = viewModel.sleepTimerRemaining else { return String(localized: "Sleep") }
        let minutes = Int(remaining) / 60
        let seconds = Int(remaining) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var body: some View {
        Menu {
            // The duration of the last time, at the top and in one tap.
            // Only shown while no timer runs, and only when it is not
            // already the first row anyway.
            if !running,
               let last = AppStorageKeys.sleepTimerRemembered,
               last != Self.options.first {
                Button("Again: \(DurationText.length(minutes: Int(last)))") {
                    viewModel.startSleepTimer(minutes: last)
                }
                Divider()
            }
            ForEach(Self.options, id: \.self) { minutes in
                Button(DurationText.length(minutes: Int(minutes))) {
                    viewModel.startSleepTimer(minutes: minutes)
                }
            }
            // Music has no "chapter" boundary. "Until End of Track"
            // (below) is the song boundary, so skip the chapter option.
            if !viewModel.chapters.isEmpty && !viewModel.isMusicItem {
                Button("Until End of Chapter") {
                    viewModel.startSleepTimerUntilChapterEnd()
                }
            }
            if viewModel.canSleepUntilTrackEnd {
                Button("Until End of Track") {
                    viewModel.startSleepTimerUntilTrackEnd()
                }
            }
            if running {
                Divider()
                Button("+15 min") {
                    viewModel.extendSleepTimer(byMinutes: 15)
                }
                Button("Stop Timer", role: .destructive) {
                    viewModel.cancelSleepTimer()
                }
            }
        } label: {
            // Active timer: filled icon + accent color + live countdown.
            // The status is visible at a glance, not only inside the menu.
            let symbol = running ? "moon.zzz.fill" : "moon.zzz"
            Group {
                if columnCell {
                    // Only the number under the glyph; the spoken label
                    // keeps the unit.
                    let minutes = viewModel.sleepTimerRemaining.map { Int(($0 / 60).rounded(.up)) }
                    VStack(spacing: 1) {
                        Image(systemName: symbol)
                        if let minutes {
                            Text(verbatim: "\(minutes)")
                                .font(.caption2.monospacedDigit())
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(minutes.map { DurationText.length(minutes: $0) } ?? label))
                } else if iconOnly {
                    Image(systemName: symbol)
                        .accessibilityLabel(Text(label))
                } else {
                    Label(label, systemImage: symbol)
                }
            }
            .foregroundStyle(running ? AnyShapeStyle(AppTheme.accent)
                                     : (iconOnly || columnCell ? AnyShapeStyle(.primary) : AnyShapeStyle(.white)))
        }
    }
}
