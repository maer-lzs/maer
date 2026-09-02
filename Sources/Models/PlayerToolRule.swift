// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Which tools the player's extras row shows for the running title.
///
/// Every tool appears BECAUSE the title's kind or source knows it, never
/// because it is not something else: a positive assignment, so a future
/// family (a new server, a new stream kind) inherits nothing by accident.
/// Fewer buttons that all do something beat more buttons of which some do
/// nothing.
nonisolated enum PlayerToolRule {
    enum Tool: CaseIterable, Sendable {
        case queue
        case bookmarks
        case lyrics
        case transcript
        case driveMode
        case markFinished
        case playlist
        case source
    }

    /// What the running title IS, as far as the tools are concerned. A
    /// catalogue reading and a server audiobook are both spoken word; a
    /// Jamendo track and a Subsonic song are both music; a station is a
    /// stream. The family says where a title comes from, this says what
    /// it is, and the tools follow the second.
    enum Content: Sendable {
        case spokenWord
        case music
        case liveStream
    }

    struct Input: Sendable {
        var content: Content
        /// From the source, not the title: only a server that keeps
        /// bookmarks has the tool.
        var providerKeepsBookmarks: Bool
        /// Only when a text or a transcript was actually found.
        var hasLyrics: Bool
        var hasTranscript: Bool
        /// Free catalogues carry a source page to link to.
        var isCatalogue: Bool
    }

    static func tools(for input: Input) -> Set<Tool> {
        var set: Set<Tool> = [.queue, .driveMode]
        if input.providerKeepsBookmarks { set.insert(.bookmarks) }
        if input.hasLyrics { set.insert(.lyrics) }
        if input.hasTranscript { set.insert(.transcript) }
        if input.isCatalogue { set.insert(.source) }
        switch input.content {
        case .spokenWord:
            // A reading or an episode is finished at some point; a song
            // and a stream are not, so only here does the mark exist.
            set.insert(.markFinished)
            set.insert(.playlist)
        case .music:
            set.insert(.playlist)
        case .liveStream:
            break
        }
        return set
    }
}
