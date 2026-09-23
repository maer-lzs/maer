// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS


import Foundation

/// Which folder of an Audiobookshelf library an import lands in.
///
/// The library list usually carries the folders. When it does not, the one
/// lookup is asked. Its answer has THREE outcomes and not two: a folder, a
/// library without any, and a lookup that failed. The picker once folded the
/// last two into „nothing" and returned, so choosing a library did nothing
/// at all, without a word (rule 3).
nonisolated enum ImportFolder {
    enum Answer: Equatable {
        case folder(String)
        /// The library names no folder, listed or looked up.
        case none
        /// The lookup failed; the library may well have folders.
        case unreachable
    }

    static func resolve(listed: [ABSFolder]?, lookUp: () async throws -> [ABSFolder]) async -> Answer {
        if let first = listed?.first { return .folder(first.id) }
        do {
            guard let first = try await lookUp().first else { return .none }
            return .folder(first.id)
        } catch {
            return .unreachable
        }
    }
}
