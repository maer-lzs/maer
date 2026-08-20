// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine

/// eb10440: which countries feed the GENRE pages, and how their union is
/// shaped into a list. A genre is TASTE (several countries make sense), the
/// "Popular in …" row is a PLACE (exactly one) — that separation is the
/// decision, not an interpretation, so this type deliberately does not touch
/// the national row's cascade.
///
/// Measured before building (Radio Browser cannot do this server-side):
/// `countrycode=CH,DE` answers 0 stations and a repeated `countrycode`
/// parameter keeps only the first — so several countries mean several
/// queries and a union on our side.
nonisolated enum RadioGenreCountries {
    /// The selection as stored: absent = never chosen (follow the cascade),
    /// empty = WORLDWIDE as a deliberate choice. Those are different states
    /// and must stay distinguishable — a user who picks worldwide would
    /// otherwise silently fall back to their locale on the next launch.
    static func effectiveCodes(stored: [String]?, cascade: String?) -> [String] {
        if let stored { return stored }
        if let cascade, !cascade.isEmpty { return [cascade.uppercased()] }
        return []
    }

    /// Selection state for the title/link, without leaking the storage shape
    /// into the view.
    static func isWorldwide(stored: [String]?, cascade: String?) -> Bool {
        effectiveCodes(stored: stored, cascade: cascade).isEmpty
    }

    /// Toggling in the picker: an existing code leaves, a new one joins, and
    /// removing the last one lands on worldwide (an empty list is a valid
    /// choice — it is the world).
    static func toggled(_ code: String, in current: [String]) -> [String] {
        let wanted = code.uppercased()
        if let index = current.firstIndex(of: wanted) {
            var next = current
            next.remove(at: index)
            return next
        }
        return current + [wanted]
    }

    /// Cache key for the loaded page: the list must reload when the SELECTION
    /// changes, not only when the tag does.
    static func loadKey(tag: String, codes: [String]) -> String {
        tag + "|" + codes.sorted().joined(separator: ",")
    }
}

/// eb10440 point 4 + `c3a1091`: the genre list's shaping rules. Pure, so the
/// thresholds are testable without a network: votes floor, homepage present,
/// name length, name hygiene, de-dupe over the country union, and the
/// language BONUS (never a filter — 27 % of Swiss and 30 % of Austrian
/// stations carry no language at all, measured).
nonisolated enum RadioGenreCuration {
    static let minimumVotes = 10
    static let maximumNameLength = 60
    /// Below this the page shows what it has AND offers worldwide — a genre
    /// with one entry is not a list (CH sport = 1, measured).
    static let sparseThreshold = 5

    /// The raw catalog carries leading tabs and doubled spaces (`\tRadio
    /// Record`). Trimming is display hygiene, not a filter.
    static func cleanedName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    static func passes(_ station: RadioStation) -> Bool {
        let name = cleanedName(station.name)
        guard !name.isEmpty, name.count <= maximumNameLength else { return false }
        guard (station.votes ?? 0) >= minimumVotes else { return false }
        guard let homepage = station.homepage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !homepage.isEmpty else { return false }
        return true
    }

    /// The union of several countries' answers, de-duped. The same station
    /// appears under different countries with DIFFERENT uuids, so the id is
    /// not the key that works here — `displayIdentityKey` (name + domain) is
    /// the one that actually collapses them, and it is the key the browse
    /// rows already de-dupe on.
    static func deduped(_ stations: [RadioStation]) -> [RadioStation] {
        var seen = Set<String>()
        return stations.filter { seen.insert(RadioMapping.displayIdentityKey($0)).inserted }
    }

    /// Language as a SORTING bonus: stations whose language matches the
    /// device come first, everyone else keeps plain vote order. Deliberately
    /// not three tiers — demoting a declared other language below undeclared
    /// ones would be a filter under another name, and the decision rejects a
    /// language filter.
    static func ranked(_ stations: [RadioStation], deviceLanguage: String?) -> [RadioStation] {
        guard let wanted = deviceLanguage?.lowercased(), !wanted.isEmpty else { return stations }
        let matching = stations.filter { speaks($0, wanted) }
        guard !matching.isEmpty else { return stations }
        let rest = stations.filter { !speaks($0, wanted) }
        return matching + rest
    }

    static func speaks(_ station: RadioStation, _ language: String) -> Bool {
        (station.languageCodes ?? []).contains { $0.lowercased() == language }
    }

    /// The whole pipeline in the order it must run: union → de-dupe →
    /// curation → language bonus. Votes order comes from the API.
    static func page(_ union: [RadioStation], deviceLanguage: String?) -> [RadioStation] {
        ranked(deduped(union).filter(passes), deviceLanguage: deviceLanguage)
    }

    /// G8: visibly incomplete instead of silently thin. Worldwide is already
    /// the whole catalog — there is no wider fallback to offer there.
    static func offersWorldwide(count: Int, isWorldwide: Bool) -> Bool {
        !isWorldwide && count < sparseThreshold
    }
}

/// e77e0b1 (GT R6): the ONE observed source of the genre-country selection.
///
/// The selection is app-wide (one UserDefaults key, all genre pages), but each
/// page used to hold a private `@State` COPY read once at init — two truths,
/// and on the device a change did not reach the visible list until restart.
/// The sim never hit the owner's exact constellation, so this is deliberately not
/// a point fix for one path: a shared observed object is the only construction
/// that updates EVERY mounted page at the moment of the change, whatever the
/// navigation cache did.
@MainActor
final class RadioGenreCountrySelection: ObservableObject {
    static let shared = RadioGenreCountrySelection()

    /// Absent = never chosen (cascade decides); empty = worldwide, chosen.
    @Published private(set) var stored: [String]?

    init(defaults: UserDefaults = .standard) {
        stored = defaults.array(forKey: AppStorageKeys.radioGenreCountryCodes) as? [String]
    }

    func store(_ codes: [String]) {
        stored = codes
        UserDefaults.standard.set(codes, forKey: AppStorageKeys.radioGenreCountryCodes)
    }
}
