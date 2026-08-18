// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What a source is used FOR. the owner's rule: "everything that can do several
/// things should be able to do them at the same time — people set up ONE
/// server and want to be done, not ten."
///
/// Until now a Subsonic server was one thing OR the other, stored as a single
/// content type. Two capabilities need two answers — and the old single answer
/// has to keep meaning what it meant, without anyone touching anything.
nonisolated struct SourceModes: Equatable, Sendable {
    var servesMusic: Bool
    var servesAudiobooks: Bool

    var isEmpty: Bool { !servesMusic && !servesAudiobooks }
    var count: Int { (servesMusic ? 1 : 0) + (servesAudiobooks ? 1 : 0) }

    /// Reading the OLD single value as the new pair. This is the whole
    /// migration: no write, no flag, no one-time pass — the stored content
    /// type simply reads as "this one on, the other off". A stock that was
    /// never touched keeps behaving exactly as it did.
    static func fromLegacyContentType(_ raw: String?) -> SourceModes {
        let isAudiobooks = raw == "audiobooks"
        return SourceModes(servesMusic: !isAudiobooks, servesAudiobooks: isAudiobooks)
    }

    /// The legacy value a pair still maps to, for everything that has not been
    /// taught the pair yet. With exactly one mode this is lossless; with both
    /// on, the audiobook side is the one that needs the special mapping
    /// (albums as books), so it wins the single slot until the library
    /// assignment exists.
    var legacyContentType: String {
        servesAudiobooks ? "audiobooks" : "music"
    }

    /// Several modes need to know WHICH library feeds which type — a server
    /// separates on exactly that level. Until that assignment exists, a second
    /// mode is visibly incomplete rather than a tab that stays empty (G8).
    ///
    /// With ONE mode there is nothing to assign: it behaves exactly as before,
    /// which is the promise this rule has to keep more than any other.
    var needsLibraryAssignment: Bool { count > 1 }
}
