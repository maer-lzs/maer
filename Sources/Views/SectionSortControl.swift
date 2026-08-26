// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// What the section header says about the ACTIVE sort/filter.
///
/// Pure so the rule is testable: only DEVIATIONS from the default are named.
/// That is the whole point of the move — today a filtered grid looks broken
/// rather than filtered, because nothing on the surface says it is narrowed.
nonisolated enum SortIndicator {
    /// Joins the non-default parts; nil when everything is at its default and
    /// the control stays a bare symbol.
    static func summary(_ parts: [String?]) -> String? {
        let kept = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return kept.isEmpty ? nil : kept.joined(separator: " · ")
    }

    /// A part that only shows up once it deviates.
    static func part(_ label: @autoclosure () -> String, ifNot isDefault: Bool) -> String? {
        isDefault ? nil : label()
    }
}

/// Not a glass button but a plain control at the surface it sorts — no glass,
/// no background, no border, in the accent colour.
///
/// The idiom is the existing Land-ändern-Zeile unter den Radio
/// rows (small, secondary, no surface), not a new machinery. The active value
/// appears as a short caption in front of the symbol as soon as it deviates:
/// a bare symbol does not say WHAT it is sorted by.
struct SectionSortControl<MenuContent: View>: View {
    /// nil = everything at its default, so only the symbol shows.
    let activeLabel: String?
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        Menu {
            menu()
        } label: {
            HStack(spacing: 5) {
                if let activeLabel {
                    Text(activeLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "arrow.up.arrow.down")
                    .font(.subheadline.weight(.semibold))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Sort and filter"))
        .accessibilityValue(Text(activeLabel ?? String(localized: "Default")))
        .accessibilityIdentifier("section-sort-control")
    }
}
