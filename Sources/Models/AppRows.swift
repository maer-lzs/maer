// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// ONE tile row as the rows page knows it: where it lives, whether it can
/// be hidden, and which foreign sources it draws from.
///
/// The relation to the sources is DATA and lives HERE, at the consumer:
/// a row declares its sources, and the source side derives its rows by
/// inversion. One truth, readable from both ends. The cleanup rule needs
/// exactly this edge, and deriving it from code would be a guess.
nonisolated struct AppRow: Identifiable, Sendable {
    enum Tab: String, CaseIterable, Sendable {
        case home, audiobooks, music, podcasts, radio
    }

    let key: String
    let tab: Tab
    let title: String
    /// Keys into `ExternalSources`. Empty means the row draws from the
    /// user's own holdings and no foreign service.
    let sourceKeys: [String]
    /// The visibility key. Existing keys are REUSED so no stored choice
    /// resets; rows that never had a switch get a new one. nil for the
    /// fixed rows: a key nobody ever reads or writes would still demand a
    /// sync class, a phantom in the birth gate.
    let storageKey: String?
    /// The second line of a switchable row that draws from no foreign
    /// source: what it shows instead (`AppRows.subline`).
    var note: String? = nil
    /// The library's working set (continue listening, the subscription
    /// grid, playlists, downloads) IS the library rather than a row over
    /// it. Those stay, and the rows page says so instead of offering a
    /// switch that would hide someone's own belongings.
    var toggleable: Bool { storageKey != nil }

    var id: String { key }
}

/// Every tile row, per tab, measured at the code on 30.08. The completeness
/// question of the order is answered by this list plus the fence that every
/// declared source key resolves.
nonisolated enum AppRows {
    static let all: [AppRow] = [
        // MARK: Start
        AppRow(key: "home.continue", tab: .home,
               title: String(localized: "Keep Listening"),
               sourceKeys: [], storageKey: nil),
        AppRow(key: "home.upNext", tab: .home,
               title: String(localized: "Up Next"),
               sourceKeys: [], storageKey: nil),
        AppRow(key: "home.discoverBooks", tab: .home,
               title: String(localized: "Discover · Audiobooks and Radio Plays"),
               sourceKeys: ["librivox", "gutenberg", "internetArchive"],
               storageKey: AppStorageKeys.rowHomeDiscoverBooksVisible),
        AppRow(key: "home.discoverMusic", tab: .home,
               title: String(localized: "Discover · Music"),
               sourceKeys: ["jamendo", "internetArchive"],
               storageKey: AppStorageKeys.rowHomeDiscoverMusicVisible),
        AppRow(key: "home.recommendations", tab: .home,
               title: String(localized: "Recommended"),
               // The pool comes from the ONE directory selection
               // (`PodcastDirectorySelection`): PodcastIndex where a key
               // is configured, Apple otherwise.
               sourceKeys: ["appleCatalog", "podcastIndex"],
               storageKey: AppStorageKeys.homeRecommendations),
        AppRow(key: "home.rediscover", tab: .home,
               title: String(localized: "Rediscover"),
               sourceKeys: [], storageKey: AppStorageKeys.rowHomeRediscoverVisible,
               note: String(localized: "From your own holdings.")),
        AppRow(key: "home.recentlyAdded", tab: .home,
               title: String(localized: "Recently Added"),
               sourceKeys: [], storageKey: AppStorageKeys.rowHomeRecentlyAddedVisible,
               note: String(localized: "From your own holdings.")),

        // MARK: Audiobooks
        AppRow(key: "books.search", tab: .audiobooks,
               title: String(localized: "Audiobook Search"),
               // Not a row: the BOOK scope of the search fans out to the
               // catalog clients. It asks only on the user's own query, so
               // it keeps its sources ALIVE for the cleanup rule even when
               // every discover row is hidden.
               sourceKeys: ["librivox", "gutenberg", "internetArchive"],
               storageKey: nil),
        AppRow(key: "books.catalog", tab: .audiobooks,
               title: String(localized: "Audiobooks and Radio Plays"),
               sourceKeys: ["librivox", "gutenberg", "internetArchive"],
               storageKey: AppStorageKeys.freeAudiobooksEnabled),
        AppRow(key: "books.localFiles", tab: .audiobooks,
               title: String(localized: "Local Files"),
               sourceKeys: [], storageKey: nil),
        AppRow(key: "books.continue", tab: .audiobooks,
               title: String(localized: "Keep Listening"),
               sourceKeys: [], storageKey: nil),
        AppRow(key: "books.recentlyAdded", tab: .audiobooks,
               title: String(localized: "Recently Added"),
               sourceKeys: [], storageKey: AppStorageKeys.rowBooksRecentVisible,
               note: String(localized: "From your own holdings.")),

        // MARK: Music
        AppRow(key: "music.listenAgain", tab: .music,
               title: String(localized: "Listen Again"),
               sourceKeys: [], storageKey: nil),
        AppRow(key: "music.netlabels", tab: .music,
               title: String(localized: "Netlabels"),
               sourceKeys: ["internetArchive"],
               storageKey: AppStorageKeys.netlabelsRowEnabled),
        AppRow(key: "music.oldRecords", tab: .music,
               title: String(localized: "Old Records"),
               sourceKeys: ["internetArchive"],
               storageKey: AppStorageKeys.shellacRowsEnabled),
        AppRow(key: "music.jamendo", tab: .music,
               title: String(localized: "Free Music (Jamendo)"),
               sourceKeys: ["jamendo"],
               storageKey: AppStorageKeys.jamendoRowVisible),

        // MARK: Podcasts
        AppRow(key: "podcasts.continue", tab: .podcasts,
               title: String(localized: "Keep Listening"),
               sourceKeys: [], storageKey: nil),
        AppRow(key: "podcasts.radioPlays", tab: .podcasts,
               title: String(localized: "Radio Plays to Subscribe"),
               // Curated public feeds: the row fetches CONTENT the list
               // names, not a foreign directory.
               sourceKeys: [],
               storageKey: AppStorageKeys.rowPodcastsRadioPlaysVisible,
               note: String(localized: "Public radio play feeds, chosen by Mär.")),
        AppRow(key: "podcasts.recommended", tab: .podcasts,
               title: String(localized: "Recommended"),
               // Same store and selection as the home row.
               sourceKeys: ["appleCatalog", "podcastIndex"],
               storageKey: AppStorageKeys.rowPodcastsRecommendedVisible),
        AppRow(key: "podcasts.search", tab: .podcasts,
               title: String(localized: "Podcast Search"),
               sourceKeys: ["appleCatalog", "podcastIndex"],
               storageKey: nil),
        AppRow(key: "podcasts.recentEpisodes", tab: .podcasts,
               title: String(localized: "Recently Updated"),
               sourceKeys: [], storageKey: nil),

        // MARK: Radio
        AppRow(key: "radio.catalog", tab: .radio,
               title: String(localized: "Station Catalog"),
               sourceKeys: ["radioBrowser", "wikimedia"],
               storageKey: AppStorageKeys.rowRadioCatalogVisible),
        AppRow(key: "radio.search", tab: .radio,
               title: String(localized: "Station Search"),
               // The radio scope of the search asks the catalog on the
               // user's own query. Hiding the browse ROW is a presentation
               // choice and must not cost the search its source.
               sourceKeys: ["radioBrowser"],
               storageKey: nil),
        AppRow(key: "radio.stationLogos", tab: .radio,
               title: String(localized: "Station Logos"),
               // The logo chain also feeds the SAVED tiles (favorites, my
               // stations). Hiding the catalog row must therefore not
               // switch wikimedia off with it.
               sourceKeys: ["wikimedia"],
               storageKey: nil),
    ]

    static func row(key: String) -> AppRow? { all.first { $0.key == key } }

    /// Row keys that took over one switch's meaning from a key two rows
    /// shared: new key, the old one it starts from.
    static let carried: [(new: String, old: String)] = [
        (AppStorageKeys.rowHomeDiscoverBooksVisible, AppStorageKeys.freeAudiobooksEnabled),
        (AppStorageKeys.rowHomeRediscoverVisible, AppStorageKeys.homeRecommendations),
    ]

    /// A new key starts from the person's old choice, once: a key nobody
    /// set yet takes the old key's stored value. A key already set, or an
    /// old key never set (the default stands for both), is left alone.
    static func carryOldChoices(defaults: UserDefaults = .standard) {
        for (new, old) in carried where defaults.object(forKey: new) == nil {
            guard let value = defaults.object(forKey: old) as? Bool else { continue }
            defaults.set(value, forKey: new)
        }
    }

    /// The sources a row can reach on this device. PodcastIndex counts
    /// only with a key: without one it is never asked, and naming it would
    /// promise a source that does not exist here. The fact is handed in,
    /// as on the sources page, so both sides stay testable.
    static func reachableSources(_ row: AppRow,
                                 podcastIndexConfigured: Bool) -> [ExternalSource] {
        row.sourceKeys.compactMap { ExternalSources.source(key: $0) }
            .filter { $0.isSwitchable(podcastIndexConfigured: podcastIndexConfigured) }
    }

    /// The second line of a switchable row: the foreign sources it draws
    /// from, or, without any, what it shows. Every switchable row has one.
    static func subline(_ row: AppRow, podcastIndexConfigured: Bool) -> String? {
        let titles = reachableSources(row, podcastIndexConfigured: podcastIndexConfigured).map(\.title)
        guard titles.isEmpty else { return String(localized: "Draws from: \(titles.joined(separator: " · "))") }
        return row.note
    }

    /// Is this row shown? Only the row's own switch answers; there is no
    /// second, overriding level any more.
    static func isVisible(_ row: AppRow, defaults: UserDefaults = .standard) -> Bool {
        guard let storageKey = row.storageKey else { return true }
        return AppStorageKeys.boolValue(storageKey, in: defaults)
    }

    // MARK: - The edge, readable from the other end

    /// Which rows a source feeds. Derived by inversion, so there is one
    /// truth and the sources page never carries a second list that drifts.
    static func rows(feeding sourceKey: String) -> [AppRow] {
        all.filter { $0.sourceKeys.contains(sourceKey) }
    }

    // MARK: - The ONE automatic rule

    /// A source no visible row needs any more goes off WITH it, visibly and
    /// with its reason. Only this direction: it takes nothing away, it
    /// keeps the state honest. There must never be "source allowed, never
    /// asked".
    ///
    /// Pure over the visibility map so the rule is testable without a
    /// store. Returns the sources to switch off, with the rows whose
    /// hiding caused it.
    /// The ONE write path for row visibility. Hiding a row runs the
    /// cleanup rule and returns the sources that went off WITH it, so the
    /// caller can say so. Showing a row never touches a source (the other
    /// direction is explicitly forbidden).
    @discardableResult
    static func setVisible(_ row: AppRow, _ visible: Bool,
                           defaults: UserDefaults = .standard) -> [String] {
        guard let storageKey = row.storageKey else { return [] }
        defaults.set(visible, forKey: storageKey)
        guard !visible else { return [] }
        let unused = sourcesLeftUnused { isVisible($0, defaults: defaults) }
        var turnedOff: [String] = []
        for key in unused {
            guard let source = ExternalSources.source(key: key),
                  ExternalSources.isAllowed(source, defaults: defaults) else { continue }
            defaults.set(false, forKey: source.storageKey)
            turnedOff.append(key)
        }
        return turnedOff
    }

    static func sourcesLeftUnused(visibility: (AppRow) -> Bool) -> [String] {
        var used: Set<String> = []
        for row in all where visibility(row) {
            used.formUnion(row.sourceKeys)
        }
        return ExternalSources.all.map(\.key).filter { key in
            !used.contains(key) && !rows(feeding: key).isEmpty
        }
    }

    /// The gap between the two questions: a row switch may stand ON while
    /// EVERY source the row draws from is off, and the row then cannot
    /// appear anywhere. The surfaces follow the source choice silently on
    /// purpose (a chosen absence is no failure to report); the answer to
    /// "where is my row?" belongs HERE, beside the two switches. Returns
    /// the titles of the off sources when the row stands fully unsourced,
    /// nil while any source still feeds it (fewer tiles are an answer).
    static func unsourcedTitles(_ row: AppRow, podcastIndexConfigured: Bool,
                                isAllowed: (String) -> Bool) -> [String]? {
        guard !row.sourceKeys.isEmpty else { return nil }
        let sources = reachableSources(row, podcastIndexConfigured: podcastIndexConfigured)
        guard !sources.isEmpty, sources.allSatisfy({ !isAllowed($0.key) }) else { return nil }
        return sources.map(\.title)
    }
}
