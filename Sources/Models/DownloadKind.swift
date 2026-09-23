// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The kinds downloads are deleted by. Mass deletion exists only per kind,
/// in the settings; a single title is deleted from its own context menu.
///
/// The ONE rule for which downloads belong to a kind, so that deleting one
/// kind can never reach another. The prefix decides where it is certain
/// (`MediaFamily`); where it is not, the kind recorded when the download
/// started decides, and without one nothing does.
nonisolated enum DownloadKind: String, CaseIterable, Sendable {
    case audiobooks, podcasts, music

    /// The downloaded ids of this kind as the person sees them, for deletion.
    /// A book and a podcast are known by their prefix. A Subsonic or Jellyfin
    /// title carries a music prefix whether it is an album or a book (one
    /// server can serve both), so it belongs to a kind only through the kind
    /// its download was started as. Without one it belongs to NO kind: when
    /// in doubt, nothing is deleted.
    func ids(in downloaded: some Sequence<String>, recorded: [String: DownloadKind]) -> [String] {
        downloaded.filter { id in
            switch MediaFamily.of(id) {
            case .book: self == .audiobooks
            case .podcast: self == .podcasts
            case .music: recorded[id] == self
            case .radio, .catalog, .unknown: false
            }
        }
    }

    /// Music-prefixed downloads whose kind is not known. No mass deletion
    /// reaches them; each is deleted from its own context menu.
    static func unassigned(in downloaded: some Sequence<String>,
                           recorded: [String: DownloadKind]) -> [String] {
        downloaded.filter { MediaFamily.of($0) == .music && recorded[$0] == nil }
    }
}
