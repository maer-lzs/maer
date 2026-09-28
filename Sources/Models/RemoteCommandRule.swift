// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Which remote commands (lock screen, Control Center, CarPlay, headphone
/// presses) are on for what is playing, decided per item so a switch from a
/// song to an episode in one queue needs no re-registration.
///
/// Songs are a list: the title commands move between them, and the
/// skip-by-seconds commands are off, as in the system's own music app. A
/// song is music by FORM, the same answer the player's skip habit uses, so a
/// song from a free catalogue counts as one and a catalogue reading does
/// not. Books, podcasts and readings keep both (a title press there is the
/// set skip). A live stream has nothing to skip or move to.
nonisolated enum RemoteCommandRule {
    enum Kind: Equatable, Sendable {
        case songs, spoken, live
    }

    struct Enabled: Equatable, Sendable {
        let skip: Bool
        let track: Bool
    }

    /// The kind of what is playing; nothing loaded keeps both commands.
    static func kind(forItem id: String?) -> Kind {
        guard let id else { return .spoken }
        switch MediaFamily.of(id) {
        case .radio: return .live
        case .music, .catalog: return MediaFamily.isMusicByForm(id) ? .songs : .spoken
        case .book, .podcast, .unknown: return .spoken
        }
    }

    static func enabled(for kind: Kind) -> Enabled {
        switch kind {
        case .live: return Enabled(skip: false, track: false)
        case .songs: return Enabled(skip: false, track: true)
        case .spoken: return Enabled(skip: true, track: true)
        }
    }

    /// What "previous" does for songs, as in the system's music app: within
    /// the first seconds of a song it goes to the song before, later it goes
    /// to the start of this one. Before the first song of an item comes the
    /// song this session played before it; with none, the start.
    enum Back: Equatable, Sendable {
        case startOfTrack, previousTrack, songBefore, startOfItem
    }

    static let restartWindow: Double = 3

    static func back(withinTrack: Double, trackIndex: Int, hasSongBefore: Bool) -> Back {
        if withinTrack > restartWindow { return .startOfTrack }
        if trackIndex > 0 { return .previousTrack }
        return hasSongBefore ? .songBefore : .startOfItem
    }

    /// Whether the title that gives way is remembered as the song before:
    /// only a song, only when another title follows.
    static func remembersForBack(leaving previous: String?, starting next: String) -> Bool {
        guard let previous, previous != next else { return false }
        return kind(forItem: previous) == .songs
    }
}
