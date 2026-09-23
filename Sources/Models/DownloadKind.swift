// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The kinds downloads are deleted by. Mass deletion exists only in the
/// settings, per kind and once for everything; a single title is deleted
/// from its own context menu.
///
/// The ONE rule for which downloads belong to a kind, so that deleting one
/// kind can never reach another. The prefix decides where it is certain
/// (`MediaFamily`); where it is not, the kind recorded when the download
/// started decides, and without one nothing does.
nonisolated enum DownloadKind: String, CaseIterable, Sendable {
    case audiobooks, podcasts, music

    /// The one kind a source's downloads can be, from the roles it serves
    /// today: only books, only music, or `nil` when it serves both or
    /// neither. Read at the time of deletion, never stored, because a role
    /// added later makes the answer uncertain again.
    static func sole(servedTypes: Set<MediaType>) -> DownloadKind? {
        switch (servedTypes.contains(.audiobooks), servedTypes.contains(.music)) {
        case (true, false): .audiobooks
        case (false, true): .music
        default: nil
        }
    }

    /// The downloaded ids of this kind as the person sees them, for deletion.
    /// A book and a podcast are known by their prefix. A Subsonic or Jellyfin
    /// title carries a music prefix whether it is an album or a book (one
    /// server can serve both), so it belongs to a kind through the kind its
    /// download was started as, or, for a download from before that was
    /// recorded, through its source when the source serves only one kind
    /// (`sole`). Otherwise it belongs to NO kind: when in doubt, nothing is
    /// deleted.
    func ids(in downloaded: some Sequence<String>, recorded: [String: DownloadKind],
             sole: (String) -> DownloadKind?) -> [String] {
        downloaded.filter { id in
            switch MediaFamily.of(id) {
            case .book: self == .audiobooks
            case .podcast: self == .podcasts
            case .music: (recorded[id] ?? sole(id)) == self
            case .radio, .catalog, .unknown: false
            }
        }
    }

    /// Music-prefixed downloads whose kind is not known: none recorded, and
    /// a source that serves both kinds (or none). No deletion per kind
    /// reaches them; they fall from their own context menu or with deleting
    /// everything.
    static func unassigned(in downloaded: some Sequence<String>, recorded: [String: DownloadKind],
                           sole: (String) -> DownloadKind?) -> [String] {
        downloaded.filter { MediaFamily.of($0) == .music && recorded[$0] == nil && sole($0) == nil }
    }
}
