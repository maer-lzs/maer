// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Up to three rising bars beside a track, filled by how often it was
/// played (`MusicPopularity.bars`). They grow with the text, and VoiceOver
/// says the level in words, since the shape alone carries it.
struct PopularityBars: View {
    let level: Int
    @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 11

    var body: some View {
        HStack(alignment: .bottom, spacing: height * 0.18) {
            ForEach(1...3, id: \.self) { step in
                Capsule()
                    .fill(step <= level ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                    .frame(width: height * 0.28, height: height * CGFloat(step) / 3)
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityElement()
        .accessibilityLabel(Text(Self.label(level)))
    }

    static func label(_ level: Int) -> String {
        switch level {
        case 3: return String(localized: "Played often")
        case 2: return String(localized: "Played sometimes")
        default: return String(localized: "Played rarely")
        }
    }
}

/// The mark of the song that plays: three bars in the accent that move
/// while it plays and stand still in pause. Unlike the play bars on the
/// right they are level, coloured and moving, so the two never read as one.
struct PlayingBars: View {
    let moving: Bool
    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = 14
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let moves = moving && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moves)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: height * 0.16) {
                ForEach(0..<3, id: \.self) { bar in
                    Capsule()
                        .fill(AppTheme.accent)
                        .frame(width: height * 0.22,
                               height: height * Self.share(bar: bar, at: time, moving: moves))
                }
            }
            .frame(height: height, alignment: .bottom)
        }
        .accessibilityElement()
        .accessibilityLabel(Text(moving ? "Playing now" : "Paused"))
    }

    /// The height of one bar as a share of the full height: still shares
    /// in pause, a wave of its own per bar while playing.
    nonisolated static func share(bar: Int, at time: Double, moving: Bool) -> CGFloat {
        let still: [CGFloat] = [0.45, 0.8, 0.6]
        guard moving else { return still[bar % 3] }
        let speeds = [5.1, 6.7, 4.3]
        return 0.25 + 0.75 * CGFloat((sin(time * speeds[bar % 3]) + 1) / 2)
    }
}

/// One track row of an album or a playlist, server or device: the lead
/// (an album's track number, a playlist's small cover), the title with the
/// artist below it in a playlist, the play bars when there are any, the
/// duration when known. The song that plays shows `PlayingBars` in place
/// of the lead (`TrackPlaying`). Its own view so the row can be looked at
/// on its own, at every text size.
struct TrackRowLabel: View {
    enum Lead {
        case number(Int)
        /// The song's small cover; the symbol stands in without one.
        case cover(URL?, placeholder: String)
    }

    let lead: Lead
    let title: String
    var artist: String? = nil
    /// A device playlist mixes servers: the source's short name.
    var origin: String? = nil
    /// Why a device playlist entry cannot play here, in place of the artist.
    var unavailable: String? = nil
    var duration: String? = nil
    /// What the row is, for the playing mark; without it the row shows none.
    var playing: TrackPlaying.Row? = nil
    var coordinator: PlayerCoordinator? = nil
    var bars: Int = 0
    /// The lines the line under the title may take; one for a track, as
    /// many as it needs for a routine's rule (nil), so its reason stands
    /// whole at every text size.
    var secondLines: Int? = 1
    /// Track-number column scales with Dynamic Type.
    @ScaledMetric(relativeTo: .subheadline) private var numberWidth: CGFloat = 24
    @ScaledMetric(relativeTo: .subheadline) private var coverSide: CGFloat = 40
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // Measured at AX3: beside the bars and the duration a title
                // kept four letters. Here it takes the line, and the rest
                // stands on the right below it.
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        leadSlot
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).frame(maxWidth: .infinity, alignment: .leading)
                            secondLine
                        }
                    }
                    facts
                }
            } else {
                HStack(spacing: 12) {
                    leadSlot
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).lineLimit(1)
                        secondLine.lineLimit(secondLines)
                    }
                    Spacer()
                    facts
                }
            }
        }
        .contentShape(Rectangle())
    }

    /// The lead, or the playing mark in its place.
    @ViewBuilder private var leadSlot: some View {
        if let playing, let coordinator {
            TrackLeadSlot(coordinator: coordinator, row: playing, size: leadSize) { leadView }
        } else {
            leadView
        }
    }

    /// The place the mark takes: the number's column, leading, or the
    /// cover's square, centred.
    private var leadSize: TrackLeadSize {
        switch lead {
        case .number: TrackLeadSize(width: numberWidth, height: nil, alignment: .leading)
        case .cover: TrackLeadSize(width: coverSide, height: coverSide, alignment: .center)
        }
    }

    @ViewBuilder private var leadView: some View {
        switch lead {
        case .number(let number):
            // Leading in its column, so the number is the row's first mark
            // and stands where every list's first mark stands (beside the
            // fold too).
            Text("\(number)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: numberWidth, alignment: .leading)
        case .cover(let url, let placeholder):
            CachedAsyncImage(url: url, useThumbnail: true) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .overlay(Image(systemName: placeholder).foregroundStyle(.secondary))
            }
            .frame(width: coverSide, height: coverSide)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    /// The artist (with the source on a device playlist), or the reason
    /// the entry does not play here. Nothing in an album row.
    @ViewBuilder private var secondLine: some View {
        if let unavailable {
            Text(verbatim: unavailable)
                .font(.caption).foregroundStyle(.secondary)
        } else if origin != nil || artist != nil {
            HStack(spacing: 6) {
                if let origin {
                    OriginCapsule(compact: true, text: origin, systemImage: nil)
                }
                if let artist {
                    Text(verbatim: artist).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// How often this track was played, beside it instead of a second list
    /// above, and its duration.
    private var facts: some View {
        HStack(spacing: 12) {
            if bars > 0 {
                PopularityBars(level: bars)
            }
            if let duration {
                Text(duration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct TrackLeadSize {
    let width: CGFloat
    let height: CGFloat?
    let alignment: Alignment
}

/// The lead of a row whose list belongs to the session that plays, or
/// may: observed HERE, in the small leaf, so a song change redraws one
/// slot and not the list.
private struct TrackLeadSlot<Lead: View>: View {
    @ObservedObject var coordinator: PlayerCoordinator
    let row: TrackPlaying.Row
    let size: TrackLeadSize
    @ViewBuilder let lead: () -> Lead

    var body: some View {
        if let viewModel = coordinator.viewModel {
            TrackLeadMark(viewModel: viewModel, playingId: coordinator.activeItem?.id,
                          row: row, size: size, lead: lead)
        } else {
            lead()
        }
    }
}

/// The session's song and play state, read in the leaf that shows them.
private struct TrackLeadMark<Lead: View>: View {
    @ObservedObject var viewModel: PlayerViewModel
    let playingId: String?
    let row: TrackPlaying.Row
    let size: TrackLeadSize
    @ViewBuilder let lead: () -> Lead

    var body: some View {
        if TrackPlaying.isCurrent(row, playingId: playingId,
                                  playingChapterStart: viewModel.currentChapter?.start) {
            PlayingBars(moving: viewModel.isPlaying)
                .frame(width: size.width, height: size.height, alignment: size.alignment)
        } else {
            lead()
        }
    }
}
