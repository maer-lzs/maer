// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What a source is used FOR. the user's rule: "everything that can do several
/// things should be able to do them at the same time. People set up ONE
/// server and want to be done, not ten."
///
/// Until now a Subsonic server was one thing OR the other, stored as a single
/// content type. Two capabilities need two answers. And the old single answer
/// has to keep meaning what it meant, without anyone touching anything.
nonisolated struct SourceModes: Equatable, Sendable {
    var servesMusic: Bool
    var servesAudiobooks: Bool

    var isEmpty: Bool { !servesMusic && !servesAudiobooks }
    var count: Int { (servesMusic ? 1 : 0) + (servesAudiobooks ? 1 : 0) }

    /// The pair as media types. The form every gate downstream wants.
    var types: [MediaType] {
        var result: [MediaType] = []
        if servesMusic { result.append(.music) }
        if servesAudiobooks { result.append(.audiobooks) }
        return result
    }

    /// A type this pair cannot express is not served. There is no third
    /// capability, and a source claiming one would only be able to guess.
    func serves(_ type: MediaType) -> Bool {
        switch type {
        case .music:      return servesMusic
        case .audiobooks: return servesAudiobooks
        default:          return false
        }
    }

    /// Reading the OLD single value as the new pair. This is the whole
    /// migration: no write, no flag, no one-time pass. The stored content
    /// type simply reads as "this one on, the other off". A stock that was
    /// never touched keeps behaving exactly as it did.
    static func fromLegacyContentType(_ raw: String?) -> SourceModes {
        let isAudiobooks = raw == "audiobooks"
        return SourceModes(servesMusic: !isAudiobooks, servesAudiobooks: isAudiobooks)
    }

    /// The pair projected back onto the older single content type. Nothing
    /// reads this to decide anything. The pair itself is the answer. It is
    /// written so that a stock this build touched stays readable for a build
    /// that predates the pair, and so this type stays its own inverse
    /// (`fromLegacyContentType(x.legacyContentType) == x` for one mode).
    ///
    /// It is lossy by nature, and deliberately so in both directions it can be:
    /// with both modes on, the audiobook side wins the single slot because it
    /// is the one that needs the special mapping (albums as books); and the
    /// empty pair projects to "music" because "serves nothing" is not a content
    /// type at all. That second case is an activation statement, answered where
    /// the other activation questions are answered (`subsonicActive`). Never
    /// by reading this value back.
    var legacyContentType: String {
        servesAudiobooks ? "audiobooks" : "music"
    }

    /// Several modes need to know WHICH library feeds which type. A server
    /// separates on exactly that level.
    ///
    /// With ONE mode there is nothing to assign: it behaves exactly as before,
    /// no library list is consulted and no assignment surface appears, which is
    /// the promise this rule has to keep more than any other.
    var needsLibraryAssignment: Bool { count > 1 }
}
