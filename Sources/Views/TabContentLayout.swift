// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Shared top inset and section spacing for the scrollable content of all three
/// media tabs (audiobooks / podcasts / music). One source of truth so the
/// pull-down and the gap above the first row sit identically everywhere —
/// Music was the reference.
enum TabContentLayout {
    static let topInset: CGFloat = 8
    static let sectionSpacing: CGFloat = 24
}

/// F5 Nachtrag (the owner 20.07., Gerät): the poster/tile card family is 10%
/// narrower so at least two cards fit side by side on the largest iPhone (17
/// Pro Max). ONE central home for the fixed card widths so they never drift per
/// surface (Regel 2 — the Featured card and the Recommended tile were each used
/// at two sizes). First step only — a device-loop CANDIDATE; the owner tunes the
/// exact factor on the device.
/// 6fcb301: THE cap for horizontal preview rows. Until now caps were the
/// exception — `prefix(` appeared once in HomeView, three times in
/// LibraryView, once in PodcastsView and NOT AT ALL in Music and Radio, with
/// scattered numbers (5, 15) that shared no basis. That explains several
/// findings of this week at once: "Fortsetzen" grew without bound, the radio
/// cold start was sluggish, the audiobook page loaded endlessly.
///
/// A row is the PREVIEW of a page (3a3b1aa) — the complete stock belongs
/// behind the chevron, not in the preview.
nonisolated enum RowPreview {
    /// 12 shows four screens' worth on a phone (3 columns) and two on a
    /// regular width (6) — enough to feel like a shelf, few enough to scroll
    /// past in a flick. Deliberately BELOW the 15 that "Recently added"
    /// happened to use, because that number was never chosen either.
    static let limit = 12

    /// G8: the chevron appears ONLY when there is more than the row shows.
    /// A row of three radio recents out of three total stays plain — the
    /// same rule the empty sort menu just failed.
    static func showsChevron(total: Int, shown: Int = limit) -> Bool {
        total > shown
    }

    /// The preview cut of a collection.
    static func cut<T>(_ items: [T], to limit: Int = limit) -> [T] {
        Array(items.prefix(limit))
    }
}

/// 3a3b1aa/6fcb301: THE row heading, shared by every tab. Plain text while the
/// row shows all there is; a tappable heading with a chevron as soon as
/// something is hidden behind it (G8 — no affordance without a target).
///
/// One component instead of a per-tab rebuild (Regel 2), so the rule cannot
/// drift apart between rows: whether a chevron appears is decided by
/// `RowPreview.showsChevron`, never by the call site.
struct RowHeading<Destination: Hashable>: View {
    let title: LocalizedStringKey
    /// Already-localized text (e.g. a sort option's label). Kept apart from
    /// `title` so a translated string is never looked up as a key again.
    var verbatimTitle: String?
    var font: Font = .title3
    /// The FULL stock behind the row — not the cut count.
    var total: Int = 0
    var shown: Int = RowPreview.limit
    /// nil means "this row has no page" — then it stays plain even if the cap
    /// bites, because a chevron that leads nowhere is the very thing G8 forbids.
    var destination: Destination?

    var body: some View {
        if let destination, RowPreview.showsChevron(total: total, shown: shown) {
            // Value-based push: the destination is registered once on the stack
            // root, so the same heading works from Home and from a media tab.
            NavigationLink(value: destination) {
                HStack(spacing: 6) {
                    label.font(font).bold()
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Shows the full list"))
        } else {
            label.font(font).bold().padding(.horizontal)
        }
    }

    private var label: Text {
        if let verbatimTitle { Text(verbatimTitle) } else { Text(title) }
    }
}

extension RowHeading where Destination == LibraryListRoute {
    /// A row that already shows everything it has: heading only, no target.
    /// Spelled out at the call site so "no chevron" reads as a decision.
    static func plain(_ title: LocalizedStringKey, font: Font = .title3) -> Self {
        RowHeading(title: title, font: font, total: 0, destination: nil)
    }

    /// Same, for a heading whose text is already localized (a sort label).
    static func plain(verbatim title: String, font: Font = .title3) -> Self {
        RowHeading(title: "", verbatimTitle: title, font: font, total: 0, destination: nil)
    }
}

enum CardMetrics {
    /// Large "Featured" continue-cards — books AND podcasts share this, so the
    /// two never drift apart (235 → 211, ×0.9).
    static let featuredCardWidth: CGFloat = 211
    /// Discover / Recommended catalog tiles — Home AND the podcast tab, one size
    /// (was 140 / 132; now 126, ×0.9 of the larger).
    static let recommendationTileWidth: CGFloat = 126

    // containerRelativeFrame column counts for the HORIZONTAL card rows — the
    // responsive replacement of fixed pt widths (screen-relative slots + a
    // natural peek of the next card). Design dial: the owner tunes the counts on
    // device; regular width (iPad/landscape) shows roughly double.
    static func recommendationColumns(regularWidth: Bool) -> Int { regularWidth ? 6 : 3 }
    static func playlistColumns(regularWidth: Bool) -> Int { regularWidth ? 6 : 3 }
    static func rediscoverColumns(regularWidth: Bool) -> Int { regularWidth ? 6 : 3 }
}
