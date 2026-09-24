// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What a catalogue stock run needs to know about a surface from its KEY
/// alone, so the runs can start when the app opens instead of when a page
/// appears (ENTSCHEID, GT 3.2: the indexing runs start with the app
/// and survive an update). Pure.
nonisolated enum CatalogStockSurfaces {
    /// How a surface's stock is fetched.
    enum Fetch: Equatable, Sendable {
        /// Gutenberg's catalogue dump, sliced by `Range`.
        case dump
        /// An archive.org query, scraped with a cursor.
        case archive(String)
    }

    /// The fetch of a surface, or nil for a key no page runs a stock for.
    /// The same answers the pages give (`CatalogSourcePage`,
    /// `ArchiveMusicPages`), read from the same places.
    static func fetch(for surface: String) -> Fetch? {
        if surface == CatalogSource.gutenberg.rawValue { return .dump }
        if let source = CatalogSource(rawValue: surface),
           let query = ArchiveOrgClient.archiveBaseQuery(for: source) {
            return .archive(query)
        }
        if let area = ArchiveMusicCatalog.shelf(key: surface) {
            return .archive(area.query)
        }
        return nil
    }

    /// Whether a run may reach the network for this surface: every source
    /// that serves its host must be allowed. A run at the app's start has no
    /// page that could only appear with the source on, so it asks the
    /// switch itself.
    static func mayRun(surface: String, allowed: (ExternalSource) -> Bool) -> Bool {
        let host = CatalogHostGuard.host(forSurface: surface)
        let serving = ExternalSources.all.filter { $0.hosts.contains(host) }
        return !serving.isEmpty && serving.allSatisfy(allowed)
    }

    /// The surfaces a start resumes: every one that holds a stock or an
    /// unfinished dump on this device, i.e. every collection the person
    /// once opened. A collection nobody opened does not start by itself.
    /// Derived from the file names in the stock directory.
    static func known(inDirectoryNamed names: [String]) -> [String] {
        let surfaces = names.compactMap { name -> String? in
            if name.hasSuffix(".json") { return String(name.dropLast(".json".count)) }
            if name.hasSuffix(CatalogStockFetch.partialSuffix) {
                return String(name.dropLast(CatalogStockFetch.partialSuffix.count))
            }
            return nil
        }
        return Array(Set(surfaces)).sorted()
    }
}
