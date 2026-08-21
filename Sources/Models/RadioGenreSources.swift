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
        NotificationCenter.default.addObserver(
            self, selector: #selector(choicesAdopted),
            name: .userChoicesAdopted, object: nil)
    }

    func store(_ codes: [String]) {
        stored = codes
        UserDefaults.standard.set(codes, forKey: AppStorageKeys.radioGenreCountryCodes)
        UserChoiceCloudSync.shared.noteScalar(
            key: AppStorageKeys.radioGenreCountryCodes, value: codes)
    }

    /// Choice-family adoption: re-read the ONE source, so every mounted genre
    /// page updates in place (the reason this object exists).
    @objc private nonisolated func choicesAdopted(_ note: Notification) {
        let adopted = note.userInfo?["keys"] as? [String] ?? []
        guard !adopted.isEmpty else { return }
        Task { @MainActor in
            guard adopted.contains(AppStorageKeys.radioGenreCountryCodes) else { return }
            self.stored = UserDefaults.standard.array(
                forKey: AppStorageKeys.radioGenreCountryCodes) as? [String]
        }
    }
}

/// The ONE observed source of the browse-layer country/region choices
/// ("Popular in …" country, chosen state/canton). Same construction as the
/// genre selection above: views held private `@State` COPIES read once at
/// init — two truths, and an adopted foreign choice would never have reached
/// a mounted page.
@MainActor
final class RadioBrowseSelection: ObservableObject {
    static let shared = RadioBrowseSelection()

    /// The user-chosen state/canton display name; nil = not chosen.
    @Published private(set) var chosenState: String?
    /// Explicit country choice (cascade step a).
    @Published private(set) var chosenCountryCode: String?
    @Published private(set) var chosenCountryName: String?
    /// Country implied by the chosen region (cascade step b).
    @Published private(set) var impliedCountryCode: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        chosenState = defaults.string(forKey: AppStorageKeys.radioRegionState)
        chosenCountryCode = defaults.string(forKey: AppStorageKeys.radioChosenCountryCode)
        chosenCountryName = defaults.string(forKey: AppStorageKeys.radioChosenCountryName)
        impliedCountryCode = defaults.string(forKey: AppStorageKeys.radioRegionCountryCode)
        NotificationCenter.default.addObserver(
            self, selector: #selector(choicesAdopted),
            name: .userChoicesAdopted, object: nil)
    }

    /// Region choice: display name + ALL merged raw query names (derived
    /// cache, travels as a consequence via `chosenState`) + implied country.
    func chooseRegion(display: String, queryNames: [String],
                      impliedCode: String?, impliedName: String?) {
        chosenState = display
        defaults.set(display, forKey: AppStorageKeys.radioRegionState)
        UserChoiceCloudSync.shared.noteScalar(
            key: AppStorageKeys.radioRegionState, value: display)
        defaults.set(queryNames, forKey: AppStorageKeys.radioRegionQueryNames)
        if let impliedCode {
            impliedCountryCode = impliedCode
            defaults.set(impliedCode, forKey: AppStorageKeys.radioRegionCountryCode)
            UserChoiceCloudSync.shared.noteScalar(
                key: AppStorageKeys.radioRegionCountryCode, value: impliedCode)
        }
        if let impliedName {
            defaults.set(impliedName, forKey: AppStorageKeys.radioRegionCountryName)
            UserChoiceCloudSync.shared.noteScalar(
                key: AppStorageKeys.radioRegionCountryName, value: impliedName)
        }
    }

    func clearRegion() {
        chosenState = nil
        defaults.removeObject(forKey: AppStorageKeys.radioRegionState)
        defaults.removeObject(forKey: AppStorageKeys.radioRegionQueryNames)
        UserChoiceCloudSync.shared.noteScalar(key: AppStorageKeys.radioRegionState, value: nil)
    }

    /// Explicit country choice (cascade step a) — clears the old country's
    /// region, exactly as before.
    func chooseCountry(code: String, name: String) {
        chosenCountryCode = code
        chosenCountryName = name
        defaults.set(code, forKey: AppStorageKeys.radioChosenCountryCode)
        defaults.set(name, forKey: AppStorageKeys.radioChosenCountryName)
        UserChoiceCloudSync.shared.noteScalar(
            key: AppStorageKeys.radioChosenCountryCode, value: code)
        UserChoiceCloudSync.shared.noteScalar(
            key: AppStorageKeys.radioChosenCountryName, value: name)
        chosenState = nil
        impliedCountryCode = nil
        for key in [AppStorageKeys.radioRegionState, AppStorageKeys.radioRegionQueryNames,
                    AppStorageKeys.radioRegionCountryCode, AppStorageKeys.radioRegionCountryName] {
            defaults.removeObject(forKey: key)
        }
        for key in [AppStorageKeys.radioRegionState, AppStorageKeys.radioRegionCountryCode,
                    AppStorageKeys.radioRegionCountryName] {
            UserChoiceCloudSync.shared.noteScalar(key: key, value: nil)
        }
    }

    #if DEBUG
    /// Harness seed: state only, deliberately unpersisted and never noted.
    func seedRegion(_ display: String) {
        chosenState = display
    }
    #endif

    @objc private nonisolated func choicesAdopted(_ note: Notification) {
        let adopted = note.userInfo?["keys"] as? [String] ?? []
        guard !adopted.isEmpty else { return }
        Task { @MainActor in
            let mine = [AppStorageKeys.radioRegionState, AppStorageKeys.radioChosenCountryCode,
                        AppStorageKeys.radioChosenCountryName, AppStorageKeys.radioRegionCountryCode]
            guard adopted.contains(where: { mine.contains($0) }) else { return }
            self.chosenState = self.defaults.string(forKey: AppStorageKeys.radioRegionState)
            self.chosenCountryCode = self.defaults.string(forKey: AppStorageKeys.radioChosenCountryCode)
            self.chosenCountryName = self.defaults.string(forKey: AppStorageKeys.radioChosenCountryName)
            self.impliedCountryCode = self.defaults.string(forKey: AppStorageKeys.radioRegionCountryCode)
        }
    }
}

/// 973121e (the owner, freigegeben): family collapse as a DISPLAY rule of the
/// genre lists — the sport tag is 20/25 one provider's per-match channels
/// (measured), and the flood hides that the tag is thin. Search, favorites,
/// My Stations and Recents keep showing single channels; only the genre page
/// folds.
nonisolated enum RadioGenreFamilies {

    /// One collapsed entry: the front station plus its folded variants.
    struct Family: Identifiable, Equatable {
        let front: RadioStation
        /// The remaining members, input (vote) order preserved.
        let variants: [RadioStation]
        var id: String { front.id }
        var count: Int { variants.count + 1 }
    }

    /// The conservative cut (the sibling-stage lesson, applied to lists):
    /// SAME domain is mandatory, and the shared name head must come from an
    /// explicit separator (":" or " - ") — two independent "Radio 1" share
    /// neither, so they never merge. The RB catalog typo family
    /// ("Fußfball-…") stays apart honestly: a different head is a different
    /// family, we do not repair catalog spelling.
    static func familyKey(_ station: RadioStation) -> String? {
        let host = PodcastSubscriptions.feedHost(station.homepage ?? "")
        guard !host.isEmpty else { return nil }
        let name = RadioMapping.displayName(station.name)
        let separators = [": ", " - "]
        for separator in separators {
            if let range = name.range(of: separator) {
                let head = name[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                guard head.count >= 4 else { return nil }
                return host + "|" + head.lowercased()
            }
        }
        return nil
    }

    /// Collapse a vote-ordered list. Order rule: every family sits at the
    /// position of its first (best-voted) member; the front of a family is
    /// its "Konferenz" member when one exists, else that first member.
    static func collapsed(_ stations: [RadioStation]) -> [Family] {
        var members: [String: [RadioStation]] = [:]
        var order: [(key: String?, station: RadioStation)] = []
        for station in stations {
            if let key = familyKey(station) {
                if members[key] == nil { order.append((key, station)) }
                members[key, default: []].append(station)
            } else {
                order.append((nil, station))
            }
        }
        return order.map { entry in
            guard let key = entry.key, let family = members[key], family.count > 1 else {
                return Family(front: entry.station, variants: [])
            }
            let front = family.first {
                RadioMapping.displayName($0.name).lowercased().contains("konferenz")
            } ?? family[0]
            return Family(front: front, variants: family.filter { $0.id != front.id })
        }
    }
}
