// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import ABSPlayer

/// eb10440: the genre pages' country selection and list shaping.
@Suite struct RadioGenreCountriesTests {

    // MARK: - Selection

    @Test func untouchedFollowsTheCascade() {
        #expect(RadioGenreCountries.effectiveCodes(stored: nil, cascade: "CH") == ["CH"])
        #expect(RadioGenreCountries.effectiveCodes(stored: nil, cascade: "ch") == ["CH"])
    }

    /// The distinction the storage exists for: never chosen falls back to the
    /// environment, chosen-worldwide does NOT. If these collapsed, picking
    /// worldwide would silently revert to the locale on the next launch.
    @Test func chosenWorldwideIsNotTheSameAsNeverChosen() {
        #expect(RadioGenreCountries.effectiveCodes(stored: [], cascade: "CH").isEmpty)
        #expect(RadioGenreCountries.isWorldwide(stored: [], cascade: "CH"))
        #expect(!RadioGenreCountries.isWorldwide(stored: nil, cascade: "CH"))
    }

    @Test func noCascadeMeansWorldwide() {
        #expect(RadioGenreCountries.effectiveCodes(stored: nil, cascade: nil).isEmpty)
        #expect(RadioGenreCountries.effectiveCodes(stored: nil, cascade: "").isEmpty)
    }

    @Test func togglingAddsAndRemoves() {
        var codes = ["CH"]
        codes = RadioGenreCountries.toggled("DE", in: codes)
        codes = RadioGenreCountries.toggled("at", in: codes)
        #expect(codes == ["CH", "DE", "AT"])
        codes = RadioGenreCountries.toggled("DE", in: codes)
        #expect(codes == ["CH", "AT"])
    }

    /// Removing the last country is a legal state — it IS worldwide.
    @Test func removingTheLastCountryLandsOnWorldwide() {
        #expect(RadioGenreCountries.toggled("CH", in: ["CH"]).isEmpty)
    }

    /// The page must reload when the SELECTION changes, not only the tag —
    /// otherwise a country change shows the previous country's list.
    @Test func theLoadKeyCarriesTheSelection() {
        let a = RadioGenreCountries.loadKey(tag: "news", codes: ["CH"])
        let b = RadioGenreCountries.loadKey(tag: "news", codes: ["CH", "DE"])
        #expect(a != b)
        // Order of choice must not force a reload — the union is the same.
        #expect(RadioGenreCountries.loadKey(tag: "news", codes: ["DE", "CH"]) == b)
    }

    // MARK: - Curation

    private func station(_ name: String, votes: Int = 100, homepage: String? = "https://x.test",
                         id: String = UUID().uuidString,
                         languages: [String]? = nil) -> RadioStation {
        RadioStation(id: "radio:rb:\(id)", name: name, streamURL: "https://s.test/\(id)",
                     homepage: homepage, votes: votes, languageCodes: languages)
    }

    @Test func theVotesFloorRemovesCardCorpses() {
        let list = [station("Gut", votes: 10), station("Karteileiche", votes: 9)]
        #expect(RadioGenreCuration.page(list, deviceLanguage: nil).map(\.name) == ["Gut"])
    }

    @Test func aStationWithoutHomepageDrops() {
        #expect(RadioGenreCuration.page([station("Ohne", homepage: nil)], deviceLanguage: nil).isEmpty)
        #expect(RadioGenreCuration.page([station("Leer", homepage: "  ")], deviceLanguage: nil).isEmpty)
    }

    @Test func tagCarpetNamesDrop() {
        let carpet = String(repeating: "pop hits ", count: 10)
        #expect(RadioGenreCuration.page([station(carpet)], deviceLanguage: nil).isEmpty)
    }

    /// The raw catalog carries leading tabs — hygiene, not a filter.
    @Test func namesAreTrimmed() {
        #expect(RadioGenreCuration.cleanedName("\tRadio  Record ") == "Radio Record")
    }

    /// The same station under two countries has DIFFERENT uuids — the id is
    /// not the key that collapses them.
    @Test func theUnionDeDupesAcrossCountries() {
        let ch = station("Radio Swiss Pop", homepage: "https://radioswisspop.ch", id: "a")
        let de = station("Radio Swiss Pop", homepage: "https://radioswisspop.ch", id: "b")
        #expect(ch.id != de.id)
        #expect(RadioGenreCuration.page([ch, de], deviceLanguage: nil).count == 1)
    }

    // MARK: - Language is a bonus, never a filter

    @Test func matchingLanguageMovesUp() {
        let list = [station("Französisch", votes: 900, languages: ["fr"]),
                    station("Deutsch", votes: 100, languages: ["de"])]
        #expect(RadioGenreCuration.ranked(list, deviceLanguage: "de").map(\.name)
                == ["Deutsch", "Französisch"])
    }

    /// The decision's core: no language filter. A station without a language
    /// statement must survive — measured, that is 27 % of the Swiss catalog.
    @Test func stationsWithoutALanguageSurvive() {
        let list = [station("Ohne Angabe", votes: 500), station("Deutsch", votes: 100, languages: ["de"])]
        let ranked = RadioGenreCuration.ranked(list, deviceLanguage: "de")
        #expect(ranked.count == 2)
        #expect(ranked.contains { $0.name == "Ohne Angabe" })
    }

    /// A declared OTHER language must not sink below undeclared ones — that
    /// would be a filter under another name. Two tiers, not three.
    @Test func aDeclaredOtherLanguageKeepsItsVoteRank() {
        let list = [station("Couleur 3", votes: 900, languages: ["fr"]),
                    station("Webradio ohne Angabe", votes: 20)]
        #expect(RadioGenreCuration.ranked(list, deviceLanguage: "de").map(\.name)
                == ["Couleur 3", "Webradio ohne Angabe"])
    }

    @Test func noDeviceLanguageChangesNothing() {
        let list = [station("A", votes: 900, languages: ["fr"]), station("B", votes: 100, languages: ["de"])]
        #expect(RadioGenreCuration.ranked(list, deviceLanguage: nil).map(\.name) == ["A", "B"])
    }

    // MARK: - G8

    @Test func aSparseSelectionOffersWorldwide() {
        // Measured: CH sport = 1 station.
        #expect(RadioGenreCuration.offersWorldwide(count: 1, isWorldwide: false))
        #expect(RadioGenreCuration.offersWorldwide(count: 4, isWorldwide: false))
        #expect(!RadioGenreCuration.offersWorldwide(count: 5, isWorldwide: false))
    }

    /// Worldwide is already the whole catalog — there is nothing wider to
    /// offer, and offering it would be a button that does nothing.
    @Test func worldwideOffersNoWiderFallback() {
        #expect(!RadioGenreCuration.offersWorldwide(count: 0, isWorldwide: true))
    }
}

/// eb10440 carries a Codable change on a PERSISTED type. A synthesized
/// decoder does not fall back to a property's default value on a missing key
/// — it throws, and the read site swallows that with `try?`. So the test that
/// matters uses the REAL old form (a favorite stored before this change), not
/// an encode→decode round trip, which would pass either way.
@Suite struct RadioStationOldFormTests {

    /// Byte-for-byte the shape `radioFavorites` holds today: no
    /// `languageCodes` key at all.
    private let storedBeforeTheChange = """
    [{"id":"radio:rb:abc","name":"SRF 3","streamURL":"https://stream.test/srf3",\
    "homepage":"https://srf.ch","countryCode":"CH","tags":["pop"],"votes":5540}]
    """

    @Test func aFavoriteStoredBeforeTheChangeStillDecodes() throws {
        let list = try JSONDecoder().decode([RadioStation].self,
                                            from: Data(storedBeforeTheChange.utf8))
        #expect(list.count == 1)
        #expect(list[0].name == "SRF 3")
        #expect(list[0].languageCodes == nil)
    }

    /// The wire form varies in case (`de` and `DE` both occur — measured).
    @Test func wireLanguageCodesAreLowercasedAndSplit() {
        #expect(RadioMapping.languageCodes(from: "DE, fr") == ["de", "fr"])
        #expect(RadioMapping.languageCodes(from: "") == nil)
        #expect(RadioMapping.languageCodes(from: nil) == nil)
        #expect(RadioMapping.languageCodes(from: " , ") == nil)
    }

    /// The station payload without the new key must still map — the catalog
    /// is served by volunteer mirrors of varying versions.
    @Test func aWirePayloadWithoutTheFieldMaps() throws {
        let wire = """
        [{"stationuuid":"u1","name":"SRF 3","url":"https://s.test/1","homepage":"https://srf.ch"}]
        """
        let raw = try JSONDecoder().decode([RadioBrowserStation].self, from: Data(wire.utf8))
        let mapped = RadioMapping.stations(from: raw)
        #expect(mapped.count == 1)
        #expect(mapped[0].languageCodes == nil)
    }
}

/// 973121e: family collapse of the genre LISTS — the three ordered fences.
@Suite struct RadioGenreFamiliesTests {

    private func station(_ name: String, votes: Int = 100,
                         homepage: String? = "https://livecenter.sportschau.de/x",
                         id: String = UUID().uuidString) -> RadioStation {
        RadioStation(id: "radio:rb:\(id)", name: name, streamURL: "https://s.test/\(id)",
                     homepage: homepage, votes: votes)
    }

    /// The measured sportschau case: one domain, one head, the Konferenz in
    /// front — and NOTHING lost behind the fold (Vollzähligkeit).
    @Test func theSportschauFamilyCollapsesCompletely() {
        let family = [station("Fußball-Bundesliga: Spiel 1", votes: 86),
                      station("Fußball-Bundesliga: Konferenz", votes: 282),
                      station("Fußball-Bundesliga: Spiel 4", votes: 51)]
        let outsider = station("1A Fitness Hits", votes: 2430,
                               homepage: "https://1a-webradio.de")
        let collapsed = RadioGenreFamilies.collapsed([outsider] + family)
        #expect(collapsed.count == 2)
        #expect(collapsed[0].front.name == "1A Fitness Hits")
        #expect(collapsed[0].variants.isEmpty)
        // The Konferenz leads even though a Spiel came first in vote order.
        #expect(collapsed[1].front.name == "Fußball-Bundesliga: Konferenz")
        #expect(collapsed[1].count == 3)
        // Completeness: front + variants carry every member exactly once.
        let ids = Set([collapsed[1].front.id] + collapsed[1].variants.map(\.id))
        #expect(ids == Set(family.map(\.id)))
    }

    /// Conservative cut 1: two independent "Radio 1" on DIFFERENT domains
    /// never merge — the domain is mandatory, the name alone proves nothing.
    @Test func sameNameDifferentDomainStaysApart() {
        let a = station("Radio 1: Morgen", homepage: "https://radio1.ch")
        let b = station("Radio 1: Morgen", homepage: "https://radio1.de")
        #expect(RadioGenreFamilies.collapsed([a, b]).count == 2)
    }

    /// Conservative cut 2: no explicit separator, no family — plain names on
    /// one domain stay single entries (the head must be DECLARED, not
    /// guessed), and the catalog typo family ("Fußfball-…") stays apart
    /// honestly: a different head is a different family.
    @Test func headsAreDeclaredNeverGuessed() {
        let plain = [station("Sportradio"), station("Sportradio Zwei")]
        #expect(RadioGenreFamilies.collapsed(plain).count == 2)
        let typo = [station("Fußball-Bundesliga 2: Spiel 1"),
                    station("Fußfball-Bundesliga 2: Spiel 2")]
        #expect(RadioGenreFamilies.collapsed(typo).count == 2)
    }

    /// Solo "families": one member never shows a fold — a hint reading
    /// "1 channels" would be noise.
    @Test func aSingleMemberIsNoFamily() {
        let solo = RadioGenreFamilies.collapsed([station("Fußball-Bundesliga: Konferenz")])
        #expect(solo.count == 1)
        #expect(solo[0].variants.isEmpty)
    }
}

/// c0674d4: the multi-country group's failure semantics — a cancel is not a
/// failure in the COUNT either. Three refresh-cancels produced
/// cannotConnectToHost ("Verbindungsfehler" on intact net), one level above
/// the fixed single catches.
@Suite struct RadioGroupVerdictTests {

    @Test("drei Cancels sind eine Cancellation, kein Verbindungsfehler")
    func cancelsAreNoFailures() {
        #expect(RadioBrowserClient.groupVerdict(hitCount: 0, cancelCount: 3, total: 3) == .cancelled)
    }

    @Test("alle Laender ECHT gescheitert = unerreichbar")
    func allRealFailuresAreUnreachable() {
        #expect(RadioBrowserClient.groupVerdict(hitCount: 0, cancelCount: 0, total: 3) == .unreachable)
    }

    @Test("ein Treffer traegt die Seite — egal was die anderen taten")
    func anyHitCarries() {
        #expect(RadioBrowserClient.groupVerdict(hitCount: 1, cancelCount: 2, total: 3) == .union)
        #expect(RadioBrowserClient.groupVerdict(hitCount: 1, cancelCount: 0, total: 3) == .union)
    }

    @Test("gemischt ohne Treffer: ein Cancel macht den Lauf zum Abbruch")
    func mixedWithoutHitsIsCancelled() {
        #expect(RadioBrowserClient.groupVerdict(hitCount: 0, cancelCount: 1, total: 3) == .cancelled)
    }
}
