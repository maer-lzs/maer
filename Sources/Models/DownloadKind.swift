// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The kinds downloads are deleted by. Mass deletion exists only per kind,
/// in the settings; a single title is deleted from its own context menu.
///
/// The ONE rule for which downloads belong to a kind, so that deleting one
/// kind can never reach another. It asks `MediaFamily`, the rule that maps an
/// id to its family everywhere else.
nonisolated enum DownloadKind: String, CaseIterable, Sendable {
    case audiobooks, podcasts, music

    var family: MediaFamily {
        switch self {
        case .audiobooks: .book
        case .podcasts: .podcast
        case .music: .music
        }
    }

    /// The downloaded ids of this kind, and no others.
    func ids(in downloaded: some Sequence<String>) -> [String] {
        downloaded.filter { MediaFamily.of($0) == family }
    }
}
