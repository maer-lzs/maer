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
    /// 78rpm-era classical (georgeblood). Carries NO `licenseurl` at all —
    /// the recording year is the only rights hint, so no capsule appears and
    /// nothing claims public domain (P6a).
    static let classical = ArchiveMusicArea(
        key: "free-classical",
        query: "collection:georgeblood AND subject:classical AND mediatype:(audio)",
        title: String(localized: "Free Classical"),
        headerNote: String(localized: "Free public-domain recordings from the Internet Archive — separate from your own library."),
        placeholderSystemImage: "music.quarternote.3",
        measuredTotal: 4_271)

    /// Netlabel releases under Creative Commons. Measured 08.08.: 76.950
    /// audio items, 61.111 WITH a stated licence — the query keeps only
    /// those, so every tile SHOWS its licence instead of the app guessing
    /// (mostly NC/ND variants, which is exactly why the capsule matters).
    static let netlabels = ArchiveMusicArea(
        key: "netlabels",
        query: "collection:netlabels AND mediatype:(audio) AND licenseurl:[* TO *]",
        title: String(localized: "Netlabels"),
        headerNote: String(localized: "Creative-Commons releases from netlabels on the Internet Archive — separate from your own library. Each tile shows the licence of its release."),
        placeholderSystemImage: "opticaldisc",
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
    static var all: [ArchiveMusicArea] { [classical, netlabels] + shellacShelves }
}
