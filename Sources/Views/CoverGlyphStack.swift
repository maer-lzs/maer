// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The tone of every mark and pill on a cover or card: the fill of the
/// card's Details pill over a dark disc, so it carries on a light cover
/// too. One place, so a change of tone is these lines.
enum GlyphTone {
    static let fill = Color.white.opacity(0.22)
    static let shade = Color.black.opacity(0.35)
}

extension View {
    /// THE disc of a mark or a corner control on a cover: the dark shade,
    /// the tone over it.
    func glyphDisc() -> some View {
        background {
            ZStack {
                Circle().fill(GlyphTone.shade)
                Circle().fill(GlyphTone.fill)
            }
        }
    }

    /// The same tone as a capsule: the pills and corner buttons of a card.
    func glyphCapsule() -> some View {
        background {
            ZStack {
                Capsule().fill(GlyphTone.shade)
                Capsule().fill(GlyphTone.fill)
            }
        }
    }
}

/// THE stack of state marks at the top right of a cover: the marks the
/// tile carries, one under the other in the order of `CoverGlyphs`, as
/// many as fit above the bottom right control. A mark that does not fit
/// is still said to VoiceOver. Each mark keeps its own view and its own
/// inset, so a single mark stands where it stood alone. The marks grow
/// with the text up to the first accessibility size and no further:
/// measured at AX3, a 150 pt tile held only one grown mark above its play
/// control.
struct CoverGlyphStack<Glyph: View>: View {
    let present: [CoverGlyph]
    /// The side of the cover, nil until measured (hides nothing).
    let coverSide: CGFloat?
    /// The side of the control at the bottom right, as the tile draws it.
    let cornerSide: CGFloat
    /// What VoiceOver hears for a mark that does not fit.
    let label: (CoverGlyph) -> Text
    @ViewBuilder let glyph: (CoverGlyph) -> Glyph

    /// The largest text size the marks grow with.
    static var largestSize: DynamicTypeSize { .accessibility1 }

    var body: some View {
        Marks(present: present, coverSide: coverSide, cornerSide: cornerSide, label: label, glyph: glyph)
            .dynamicTypeSize(...Self.largestSize)
    }

    /// The marks under the capped text size, so the height of one mark is
    /// measured at the size they are drawn in.
    private struct Marks: View {
        let present: [CoverGlyph]
        let coverSide: CGFloat?
        let cornerSide: CGFloat
        let label: (CoverGlyph) -> Text
        let glyph: (CoverGlyph) -> Glyph
        /// The height one mark takes in the stack: the offline disc and the
        /// lock with their insets.
        @ScaledMetric(relativeTo: .title3) private var glyphSide: CGFloat = 32

        var body: some View {
            let room = CoverGlyphs.room(coverSide: coverSide.map(Double.init), glyphSide: glyphSide,
                                        cornerSide: cornerSide)
            let split = CoverGlyphs.stack(present, room: room)
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(split.shown, id: \.self) { glyph($0) }
            }
            // Marks are states, not controls: a tap on one reaches the tile.
            .allowsHitTesting(false)
            .overlay {
                if let first = split.hidden.first {
                    Color.clear
                        .accessibilityElement()
                        .accessibilityLabel(split.hidden.dropFirst().reduce(label(first)) { $0 + Text(verbatim: ", ") + label($1) })
                }
            }
        }
    }
}

/// The stack with the standard view of every mark, for a tile that only
/// hands over its states: kind, lock, availability, finished, favourite,
/// count. A mark is present only when it has something to say.
struct StandardCoverMarks: View {
    var kind: MediaType? = nil
    var lock: FeedLock? = nil
    var availability: CoverAvailability? = nil
    var finished = false
    var favourite = false
    var count: Int? = nil
    let coverSide: CGFloat?
    var cornerSide: CGFloat = 0
    @ScaledMetric(relativeTo: .title3) private var diameter: CGFloat = 22

    private var marks: [CoverGlyph] {
        (kind == nil ? [] : [.kind]) + ((lock ?? .none) == .none ? [] : [.lock])
            + (availability == nil ? [] : [.availability]) + (finished ? [.finished] : [])
            + (favourite ? [.favourite] : []) + (count == nil ? [] : [.count])
    }

    var body: some View {
        CoverGlyphStack(present: marks, coverSide: coverSide, cornerSide: cornerSide, label: label) { mark in
            switch mark {
            case .kind: if let kind { KindGlyph(kind: kind) }
            case .lock: if let lock { PremiumLockBadge(lock: lock) }
            case .availability: availabilityMark
            case .finished: disc("checkmark").accessibilityLabel(Text("Finished"))
            case .favourite: disc("star.fill").accessibilityLabel(Text("Favorite"))
            case .count:
                if let count {
                    Text("\(count)")
                        .font(.caption2.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(.red))
                        .padding(7)
                }
            }
        }
    }

    private func label(_ mark: CoverGlyph) -> Text {
        switch mark {
        case .kind: Text(verbatim: kind?.label ?? "")
        case .lock: lock == .refused ? Text("Access refused") : Text("Premium Feed")
        case .availability:
            switch availability {
            case .failed: Text("Download failed")
            case .downloaded: Text("Downloaded")
            default: Text("Not available offline")
            }
        case .finished: Text("Finished")
        case .favourite: Text("Favorite")
        case .count: Text(verbatim: "\(count ?? 0)")
        }
    }

    @ViewBuilder
    private var availabilityMark: some View {
        switch availability {
        case .failed:
            // A failure keeps its signal colour, like a refused feed.
            Image(systemName: "exclamationmark")
                .font(.system(size: diameter * 0.45, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(AppTheme.accent))
                .padding(5)
                .accessibilityLabel(Text("Download failed"))
        case .downloaded: DownloadedMark(size: .large).padding(4)
        case .offline: OfflineUnavailableBadge().padding(5)
        case nil: EmptyView()
        }
    }

    /// A white symbol on the disc of the tone, as large as the offline disc.
    private func disc(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: diameter * 0.45, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .glyphDisc()
            .padding(5)
    }
}
