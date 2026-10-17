// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The shownotes of the subscribed episodes live in the database, not in
/// memory: one episode's notes are read when the episode is opened. Every
/// show that enters the stock passes `split`, which takes the notes out and
/// leaves a stamp of them on the episode, so a refresh that brings the
/// same text again writes nothing and a changed text is seen without the
/// text in memory. Foundation only, like the types it works on.
nonisolated enum PodcastNotes {
    /// The stock without notes and the notes to write, keyed by guid; nil
    /// when no episode carried notes. `stampBefore` answers the stamp the
    /// stock held for a guid: a note whose stamp is unchanged is not written
    /// again. An empty text is no note.
    static func split(_ shows: [PodcastShow],
                      stampBefore: (String) -> Int?) -> (shows: [PodcastShow], notes: [String: String])? {
        guard shows.contains(where: { $0.episodes.contains { $0.description != nil } }) else { return nil }
        var slim = shows
        var notes: [String: String] = [:]
        for s in slim.indices where slim[s].episodes.contains(where: { $0.description != nil }) {
            for e in slim[s].episodes.indices {
                guard let text = slim[s].episodes[e].description else { continue }
                slim[s].episodes[e].description = nil
                guard !text.isEmpty else { continue }
                let guid = slim[s].episodes[e].guid
                let stamp = Self.stamp(text)
                if stampBefore(guid) != stamp { notes[guid] = text }
                slim[s].episodes[e].notesStamp = stamp
            }
        }
        return (slim, notes)
    }

    /// FNV-1a over the UTF-8 bytes: the same text gives the same stamp in
    /// every run, unlike `Hasher`.
    static func stamp(_ text: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Int(bitPattern: UInt(hash))
    }
}
