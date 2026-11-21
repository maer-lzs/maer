// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Repeat in the player's music row: a tap goes off, list, song
/// (`RepeatMode`). Off stands in white, on in the accent; one song carries
/// the 1. The state belongs to this device and stays until changed; the
/// system's command and the car show the same.
struct RepeatButton: View {
    /// The player's row of symbols: the symbol at every size.
    var iconOnly = false
    @AppStorage(AppStorageKeys.musicRepeatMode) private var stored = RepeatMode.off.rawValue
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let mode = RepeatMode.stored(stored)
        Button {
            PlayerViewModel.setRepeat(mode.next)
        } label: {
            Group {
                if iconOnly || dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: Self.symbol(mode))
                        .accessibilityLabel(Text("Repeat"))
                } else {
                    Label("Repeat", systemImage: Self.symbol(mode))
                }
            }
            .foregroundStyle(mode == .off ? AnyShapeStyle(.white) : AnyShapeStyle(AppTheme.accent))
            // The player's ground is dark in every appearance.
            .environment(\.colorScheme, .dark)
        }
        .accessibilityValue(Text(Self.stateWord(mode)))
        .accessibilityIdentifier("player-repeat")
    }

    static func symbol(_ mode: RepeatMode) -> String {
        mode == .one ? "repeat.1" : "repeat"
    }

    static func stateWord(_ mode: RepeatMode) -> LocalizedStringKey {
        switch mode {
        case .off: "Off"
        case .all: "Repeat List"
        case .one: "Repeat Song"
        }
    }
}
