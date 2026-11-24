// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The address of a cover the app draws itself (a Musopen recording has no
/// picture): it carries what the drawing needs, so every surface that loads
/// a cover by its address (tiles, rows, the mini player, lists and their
/// collages, the lock screen, CarPlay, the widget) gets the same picture
/// through the one door of the covers, and no view decides by itself.
/// The version names the drawing; a new drawing takes a new version and
/// with it a new address in every cache.
nonisolated enum DrawnCover {
    static let scheme = "maer-drawn"
    /// 2: the colours of Goethe's circle (`MusopenCoverArt.art`); 3: its 24
    /// places, every composer with a pair of his own.
    static let version = "3"

    /// The address of the drawn cover of a recording.
    static func url(title: String, composer: String?) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "musopen"
        var items = [URLQueryItem(name: "t", value: title)]
        if let composer, !composer.isEmpty { items.append(URLQueryItem(name: "c", value: composer)) }
        items.append(URLQueryItem(name: "v", value: version))
        parts.setQuery(items)
        return parts.url ?? URL(string: "\(scheme)://musopen")!
    }

    /// What a drawn cover's address carries, nil for any other address.
    static func parts(of url: URL) -> (title: String, composer: String?)? {
        guard url.scheme == scheme, url.host() == "musopen",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let title = items.first(where: { $0.name == "t" })?.value else { return nil }
        return (title, items.first(where: { $0.name == "c" })?.value)
    }
}
