// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The status line of a featured card (time left · last heard, or played),
/// the one form for the book and the podcast cards. One line at the usual
/// sizes; above them two lines, held on every card, so the line wraps
/// instead of being cut and the cards of a row keep one height. The cards
/// cap their type at accessibility1.
struct CardStatusLine: View {
    let text: String
    var played = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let lines = Self.lines(for: dynamicTypeSize)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if played { Image(systemName: "checkmark.circle.fill") }
            Text(text).lineLimit(lines, reservesSpace: lines > 1)
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.85))
    }

    /// How many lines the status line holds at a type size.
    nonisolated static func lines(for size: DynamicTypeSize) -> Int {
        size > .large ? 2 : 1
    }
}

/// The words of the status line, for the cards and for the tiles of the
/// continue page, so a title says the same in the row and on its page.
extension CardStatusLine {
    /// "Playing now", or when the title was last heard: the newer of the
    /// local and the server stand, the moment the rows rank by. Nil when
    /// neither knows one.
    static func lastHeard(itemId: String, server: Double) -> String? {
        switch ListeningMoment.label(
            local: ProgressMark.timestamp(ListeningStore.backup(itemId)) ?? 0,
            server: server,
            playingNowMs: PlayingNow.momentMs(forId: itemId)) {
        case .playing: return String(localized: "Playing now")
        case .at(let ts): return Date(timeIntervalSince1970: ts / 1000).formatted(.relative(presentation: .named))
        case .none: return nil
        }
    }

    /// A book's line: time left · last heard; empty before it was started.
    static func bookText(_ entry: LibraryEntry) -> String {
        let remaining = entry.progress.flatMap { $0.isStarted ? $0.remainingText(bookDuration: entry.item.media?.duration) : nil }
        let heard = lastHeard(itemId: entry.id, server: entry.progress?.lastUpdate ?? 0)
        return [remaining, heard].compactMap { $0 }.joined(separator: " · ")
    }

    /// An episode's line: time left (or its length) · last heard (or its
    /// date); "Played" once it was heard to the end.
    static func episodeText(_ item: LibraryItem) -> String {
        let state = podcastPlayState(for: item)
        if case .played = state { return String(localized: "Played") }
        var remaining = durationText(item)
        if case .inProgress(_, let left) = state, left > 0 { remaining = DurationText.remaining(seconds: left) }
        let heard = lastHeard(itemId: item.id, server: ABSPodcastProvider.shared.episodeProgress[item.id]?.lastUpdate ?? 0)
            ?? relativeDateText(item)
        return [remaining, heard].joined(separator: " · ")
    }
}
