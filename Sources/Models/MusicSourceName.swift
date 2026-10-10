// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The name a person knows a music server by: the type
/// the server reports about itself, not the protocol it speaks. A person
/// runs "Navidrome" or "Nextcloud Music"; "Subsonic" is what the app talks.
/// One place for the name: the source capsule and the failure sentence
/// both read it.
nonisolated enum MusicSourceName {
    /// The name for a source: Jellyfin is Jellyfin; a Subsonic server is
    /// the type it reported (OpenSubsonic `type`), else "Subsonic".
    static func name(providerId: String, reportedType: String?) -> String {
        switch providerId {
        case "jf": return "Jellyfin"
        case "sub": return presented(reportedType) ?? "Subsonic"
        default: return providerId
        }
    }

    /// The source capsule of a music entry: its server's name, and only
    /// while two music servers are active. With one there is nothing to
    /// tell apart, and the pages stay as they were.
    static func capsule(serving: MusicSourceRule.Serving, name: String) -> String? {
        if case .both = serving { return name }
        return nil
    }

    /// The capsule of one entry: only MUSIC of a music server carries one,
    /// because the capsule tells two music servers apart. A catalogue or
    /// book id would otherwise fall back to the device's server and wear its
    /// name (`AlbumCell` shows catalogue tracks too), and a Jellyfin
    /// audiobook shares the music namespace but is no music.
    static func capsule(forItemId itemId: String, serving: MusicSourceRule.Serving, name: String) -> String? {
        guard MusicSourceRule.isServerMusic(itemId) else { return nil }
        return capsule(serving: serving, name: name)
    }

    /// A reported type as a name: trimmed, each word with a capital first
    /// letter ("nextcloud music" becomes "Nextcloud Music"); nil for none.
    static func presented(_ reportedType: String?) -> String? {
        guard let type = reportedType?.trimmingCharacters(in: .whitespacesAndNewlines), !type.isEmpty else {
            return nil
        }
        return type.split(separator: " ").map { word in
            word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }
}
