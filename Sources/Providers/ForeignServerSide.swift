// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What a foreign import needs of the podcast server for the shows it
/// holds: the feed handles of its episodes, its progress read fresh, and a
/// write. Audiobookshelf in the app; a witness hands in its own.
@MainActor
protocol ForeignServerSide: AnyObject {
    var episodeHandles: [String: ServerEpisodeHandle] { get }
    /// The server's progress by `abspod:` id, read now; nil when the read
    /// failed, so a state is never judged against a progress not read.
    func freshEpisodeProgress() async -> [String: BookProgress]?
    func writeEpisodeProgress(_ itemId: String, time: Double, duration: Double, finished: Bool) async throws
}

/// Why a server write could not be made at all.
nonisolated enum ForeignServerSideError: Error {
    case notAServerEpisode
}

extension ABSPodcastProvider: ForeignServerSide {}
