// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The mini player without a session (`MiniBarFill`): it names the first
/// order waiting in Up Next or the title heard last, or says that nothing
/// waits, in the bar's place and size; a tap opens Up Next.
struct IdleMiniBar: View {
    let fill: MiniBarFill
    /// The title of the waiting or last heard one, when this device knows it.
    let title: String?
    var compact: Bool = false
    /// Beside the side column, as the mini player there.
    var slim: Bool = false
    let onOpenQueue: () -> Void

    var body: some View {
        Button(action: onOpenQueue) {
            HStack(spacing: 12) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.secondary.opacity(0.15)))
                if !compact {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: title ?? Self.fallbackTitle(fill))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(Self.secondLine(fill))
                            .font(.caption2)
                            .foregroundStyle(Color.primary.opacity(0.82))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, minHeight: slim ? TabBarPlacement.sideMeasure - 2 : 48, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The mini player's surface, the same shape and tier.
        .padding(.horizontal, 12)
        .padding(.vertical, slim ? 1 : 6)
        .modifier(AdaptiveGlassBackground(shape: RoundedRectangle(cornerRadius: 30, style: .continuous),
                                          tier: slim ? SideColumnStyle.tier : .glass,
                                          morphID: nil, morphNamespace: nil))
        .accessibilityHint(Text("Opens Up Next"))
        .accessibilityIdentifier("mini-player-idle")
    }

    /// The line under the title: what the bar names.
    static func secondLine(_ fill: MiniBarFill) -> LocalizedStringKey {
        switch fill {
        case .waiting: "Waiting in Up Next"
        case .lastPlayed: "Heard last"
        case .session, .empty: "Up Next"
        }
    }

    /// The title when this device does not know the one it names.
    static func fallbackTitle(_ fill: MiniBarFill) -> String {
        switch fill {
        case .empty, .session: String(localized: "Nothing in Up Next")
        case .waiting, .lastPlayed: String(localized: "A title")
        }
    }
}
