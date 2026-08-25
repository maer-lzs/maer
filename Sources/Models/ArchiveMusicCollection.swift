// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// ONE description of an archive.org MUSIC area: what to ask for, what to
/// call it, how to mark it as an external catalog. Row, full page, settings
/// switch and search-deck tile all read from here instead of repeating the
/// same four strings — and ONE parameterised page renders any of them.
///
/// Foundation-only by rule (Befund Y): this layer carries DATA; fetching,
/// gating and rendering live in their own layers.
nonisolated struct ArchiveMusicArea: Hashable, Sendable, Identifiable {
    /// Stable key — route identifier suffix and log tag.
    let key: String
    /// The archive.org `q` parameter, verbatim.
    let query: String
    let title: String
    /// The external-catalog line at the top of the page (Katalog ≠ Bibliothek).
    let headerNote: String
    let placeholderSystemImage: String
    /// The archive.org `subject` a shelf is cut along (empty for whole-area
    /// catalogs). Kept as DATA so the UI can pick a glyph from the English
    /// term instead of the localised title.
    var subject: String = ""
    /// R-Netlabels: does this area carry a GENRE AXIS? Only the undivided
    /// collections do — a shelf area (Schellack) is already one genre, and a
    /// second cut inside it would be a shelf of a shelf.
    var hasGenreShelves: Bool = false
    /// Stock MEASURED on 09.08. — the rotation window is a tenth of it
    /// (`CatalogRotation`). Drift of a few percent only shifts the window
    /// slightly, so this does not need to be exact, only honest.
    var measuredTotal: Int = 0

    var id: String { key }
    var routeIdentifier: String { "music-route-\(key)" }
    var deckIdentifier: String { "music-\(key)" }
}

/// The music catalogs we surface, as data.
nonisolated enum ArchiveMusicCatalog {
    /// Netlabel releases under Creative Commons. Measured 08.08.: 76.950
    /// audio items, 61.111 WITH a stated licence — the query keeps only
    /// those, so every tile SHOWS its licence instead of the app guessing
    /// (mostly NC/ND variants, which is exactly why the capsule matters).
    /// R-Netlabels (the owner am Geraet: „Was ist mit Netlabels, warum ist die
    /// Seite nicht nach Genre aufgeteilt?"). Gemessen an 1.000 meistgeladenen
    /// Titeln: **93,5 % tragen ein subject-Feld** — die beste Datenlage aller
    /// Archive-Quellen (OTR 40 %, LibriVox/Gutenberg um 41 %). Die Faecher
    /// haengen also an den Subjects, nicht an der Lizenzfrage; beides ist
    /// unabhaengig, und die Sperre aus der R45-Groessenordnung traegt nicht.
    static let netlabels = ArchiveMusicArea(
        key: "netlabels",
        query: "collection:netlabels AND mediatype:(audio) AND licenseurl:[* TO *]",
        title: String(localized: "Netlabels"),
        headerNote: String(localized: "Creative-Commons releases from netlabels on the Internet Archive — separate from your own library. Each tile shows the licence of its release."),
        placeholderSystemImage: "opticaldisc",
        hasGenreShelves: true,
        measuredTotal: 61_112)

    // MARK: - Shellac 78s (the SAME collection the classical area uses)

    /// „Alte Schallplatten" is built POSITIVELY: it exists only as named
    /// genre shelves, never as one undivided view over the whole 187.034-item
    /// collection. What does not meet an inclusion criterion simply never
    /// appears — construction instead of post-filtering, so no exclusion list
    /// is needed anywhere (the counter-measurement
    /// found 0 of 46 problematic hits inside these shelves).
    ///
    /// THERE IS DELIBERATELY NO "all" ENTRY. If safety comes from the
    /// inclusion criterion, there must be no way around it — see
    /// `ArchiveMusicContractTests`, which fails if a shelf ever loses its
    /// subject constraint.
    static let shellacShelves: [ArchiveMusicArea] = [
        shellac(subject: "jazz", key: "shellac-jazz", title: String(localized: "Jazz (78s)"), total: 6_794),
        shellac(subject: "opera", key: "shellac-opera", title: String(localized: "Opera (78s)"), total: 5_818),
        // Classical is the same collection as the other shelves — measured
        // overlap with opera and jazz is 0. It used to be its own area with a
        // header claiming public domain, which the collection does not state.
        // The key stays `free-classical`: it is an address, not a title.
        shellac(subject: "classical", key: "free-classical", title: String(localized: "Classical (78s)"), total: 4_271),
        shellac(subject: "folk", key: "shellac-folk", title: String(localized: "Folk (78s)"), total: 3_834),
        shellac(subject: "blues", key: "shellac-blues", title: String(localized: "Blues (78s)"), total: 3_383),
        shellac(subject: "country", key: "shellac-country", title: String(localized: "Country (78s)"), total: 2_378),
        shellac(subject: "tango", key: "shellac-tango", title: String(localized: "Tango (78s)"), total: 1_825),
        shellac(subject: "swing", key: "shellac-swing", title: String(localized: "Swing (78s)"), total: 942),
        shellac(subject: "gospel", key: "shellac-gospel", title: String(localized: "Gospel (78s)"), total: 600),
    ]

    /// Same base as the classical area (`georgeblood`, the professionally
    /// digitised set) — measured 08.08.: jazz 6.794 · opera 5.818 · folk
    /// 3.834 · blues 3.383 · country 2.378 · tango 1.825 · swing 942 ·
    /// gospel 600. Rights presentation is the classical one: no licence
    /// field in this collection, so the recording year is the only hint and
    /// no capsule is drawn.
    static func shellac(subject: String, key: String, title: String, total: Int = 0) -> ArchiveMusicArea {
        ArchiveMusicArea(
            key: key,
            query: "collection:georgeblood AND subject:\"\(subject)\" AND mediatype:(audio)",
            title: title,
            headerNote: String(localized: "Digitised 78 rpm records from the Internet Archive — separate from your own library. The recording year is the only rights information the source states."),
            placeholderSystemImage: "opticaldisc.fill",
            subject: subject,
            measuredTotal: total)
    }

    /// Every area that has its own full page (for contract tests).
    static var all: [ArchiveMusicArea] { [netlabels] + shellacShelves }

    /// The shelf behind a key — for the few callers that address one directly
    /// (search deck, the popularity row on Home).
    static func shelf(key: String) -> ArchiveMusicArea? {
        all.first { $0.key == key }
    }

    /// The 78rpm classical shelf. Named because three call sites address it
    /// by meaning rather than by key.
    static var classical: ArchiveMusicArea {
        shelfOrFirst(key: "free-classical")
    }

    /// Resolving a selection to a shelf. An unknown or missing key falls back
    /// to a SHELF, never to the undivided collection — the safety of this area
    /// comes from its inclusion criterion, so nothing may bypass one.
    static func shelfOrFirst(key: String?) -> ArchiveMusicArea {
        key.flatMap { shelf(key: $0) } ?? shellacShelves[0]
    }
}
