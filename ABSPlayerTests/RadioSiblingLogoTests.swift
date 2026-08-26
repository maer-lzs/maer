// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import ABSPlayer

/// The sibling stage of the logo chain. The same station appears
/// several times in the catalog, and the strongest entry is not always the one
/// with a picture.
@Suite struct RadioSiblingLogoTests {

    private func wire(_ entries: [(name: String, favicon: String, homepage: String, votes: Int)]) -> Data {
        let items = entries.map {
            """
            {"stationuuid":"\(UUID().uuidString)","name":"\($0.name)","url":"https://s.test/x",\
            "favicon":"\($0.favicon)","homepage":"\($0.homepage)","votes":\($0.votes)}
            """
        }
        return Data("[\(items.joined(separator: ","))]".utf8)
    }

    /// The measured case, with its numbers.
    @Test func theWeakerEntryWithAPictureRescuesTheStrongerOne() {
        let data = wire([
            (name: "bigFM Deutschland", favicon: "", homepage: "https://www.bigfm.de/", votes: 497),
            (name: "bigFM Deutschland", favicon: "https://image.atsw.de/600x600_px.jpg",
             homepage: "https://www.bigfm.de/", votes: 88),
        ])
        let url = RadioLogoLookup.siblingFaviconURL(fromSearchData: data,
                                                    stationName: "bigFM Deutschland",
                                                    homepage: "https://www.bigfm.de/")
        #expect(url?.absoluteString == "https://image.atsw.de/600x600_px.jpg")
    }

    /// The measured trap: a HOSTING PLATFORM shares its domain with hundreds
    /// of unrelated stations. Domain alone would have handed "Deutschrap" the
    /// logo of "Laut.FM Chillharmonie". And a wrong logo is worse than a
    /// colour tile.
    @Test func aPlatformNeighbourIsNotASibling() {
        let data = wire([(name: "Laut.FM Chillharmonie", favicon: "https://laut.fm/chill.png",
                          homepage: "https://laut.fm/", votes: 568)])
        #expect(RadioLogoLookup.siblingFaviconURL(fromSearchData: data,
                                                  stationName: "Deutschrap",
                                                  homepage: "https://laut.fm/") == nil)
    }

    /// The families the rule exists for: sub-channels and language variants.
    @Test func aFamilyMemberCountsAsKin() {
        #expect(RadioLogoLookup.namesAreKin("Sunshine Live - Techno", "Sunshine Live"))
        #expect(RadioLogoLookup.namesAreKin("Radio Swiss Classic Italian", "Radio Swiss Classic"))
        #expect(RadioLogoLookup.namesAreKin("ROCK ANTENNE Soft Rock", "Rock Antenne"))
        #expect(!RadioLogoLookup.namesAreKin("Deutschrap", "Laut.FM Chillharmonie"))
        #expect(!RadioLogoLookup.namesAreKin("BR24", "Bayern 1"))
    }

    /// Kinship must not degenerate to "any two short names match".
    @Test func veryShortNamesAreNotKin() {
        #expect(!RadioLogoLookup.namesAreKin("BR", "B"))
        #expect(!RadioLogoLookup.namesAreKin("", "Rock Antenne"))
    }

    @Test func aDifferentDomainIsNeverASibling() {
        let data = wire([(name: "bigFM Deutschland", favicon: "https://other.test/a.png",
                          homepage: "https://not-bigfm.test/", votes: 900)])
        #expect(RadioLogoLookup.siblingFaviconURL(fromSearchData: data,
                                                  stationName: "bigFM Deutschland",
                                                  homepage: "https://www.bigfm.de/") == nil)
    }

    /// The strongest QUALIFYING sibling wins. Votes still rank, they just no
    /// longer decide whether there is a picture at all.
    @Test func theStrongestQualifyingSiblingWins() {
        let data = wire([
            (name: "Sunshine Live - Techno", favicon: "", homepage: "https://sunshine-live.de/", votes: 900),
            (name: "Sunshine Live", favicon: "https://sunshine-live.de/small.png",
             homepage: "https://sunshine-live.de/", votes: 100),
            (name: "Sunshine Live", favicon: "https://sunshine-live.de/big.png",
             homepage: "https://sunshine-live.de/", votes: 800),
        ])
        let url = RadioLogoLookup.siblingFaviconURL(fromSearchData: data,
                                                    stationName: "Sunshine Live - Techno",
                                                    homepage: "https://sunshine-live.de/")
        #expect(url?.absoluteString == "https://sunshine-live.de/big.png")
    }

    /// The search asks for the BRAND, not the sub-channel. "Sunshine Live -
    /// Techno" would find no siblings under its full name.
    @Test func theSearchAsksForTheBrandStem() {
        #expect(RadioLogoLookup.brandStem(of: "Sunshine Live - Techno") == "Sunshine Live")
        #expect(RadioLogoLookup.brandStem(of: "bigFM Deutschland") == "bigFM Deutschland")
        let url = RadioLogoLookup.siblingSearchURL(name: "Hit Radio FFH - 80er",
                                                   mirror: "https://de1.api.radio-browser.info")
        #expect(url?.query?.contains("name=Hit%20Radio%20FFH") == true
                || url?.query?.contains("name=Hit+Radio+FFH") == true)
    }

    /// Members without a declared separator get a SECOND, family-stem
    /// search. The brand-like first token. Generic first words never widen
    /// the search; acceptance stays domain+kinship guarded either way.
    @Test func familyStemWidensOnlyForBrandLikeHeads() {
        #expect(RadioLogoLookup.familyStem(of: "bigFM Deutsch Rap") == "bigFM")
        #expect(RadioLogoLookup.familyStem(of: "Radio Basilisk") == nil)      // generic head
        #expect(RadioLogoLookup.familyStem(of: "bigFM") == nil)               // is its own head
        #expect(RadioLogoLookup.familyStem(of: "Die Neue 107.7") == nil)      // generic article
        #expect(RadioLogoLookup.familyStem(of: "1LIVE DIGGI") == "1LIVE")     // brand-like head
        #expect(RadioLogoLookup.familyStem(of: "NRJ Bern") == nil)            // < 4 chars
        #expect(RadioLogoLookup.familyStem(of: "Sunshine Live - Techno") == "Sunshine")
    }

    /// Measured against the REAL page: bigFM's icon sits on a foreign CDN
    /// (`file.atsw.de`), not on the station's own domain. The suspicion was the
    /// absolute foreign address as the reason the homepage stage broke off.
    /// This fence holds the answer that it does not.
    @Test func anAbsoluteForeignIconAddressIsAccepted() {
        let html = """
        <html><head>\
        <link data-n-head="ssr" rel="shortcut icon" href="https://file.atsw.de/icons/icon_64.png">\
        <link data-n-head="ssr" rel="apple-touch-icon" href="https://file.atsw.de/icons/icon_512.png" sizes="512x512">\
        </head></html>
        """
        let icon = RadioLogoLookup.extractTouchIcon(html: html,
                                                    baseURL: URL(string: "https://www.bigfm.de/")!)
        #expect(icon?.absoluteString == "https://file.atsw.de/icons/icon_512.png")
    }

    /// The catalog's homepage is often `http://`. And under ATS
    /// (clear text for MEDIA only) that request never leaves the device, so
    /// the homepage stage was dead for half the German catalog (measured:
    /// 101 of the top 200). The funnel raises to https; no http fallback.
    @Test("die Homepage-Stufe hebt auf https an — kein Rueckfall")
    func homepageIsRaisedToHTTPS() {
        #expect(RadioLogoLookup.httpsPageURL("http://www.bigfm.de/webradio/deutschrap")?
            .absoluteString == "https://www.bigfm.de/webradio/deutschrap")
        #expect(RadioLogoLookup.httpsPageURL("https://www.rockantenne.de/")?
            .absoluteString == "https://www.rockantenne.de/")
        // Scheme-less catalog entries are assumed https (same as the feeds).
        #expect(RadioLogoLookup.httpsPageURL("80s80s.de")?.absoluteString == "https://80s80s.de")
        // Host and path stay untouched. Only the scheme changes.
        #expect(RadioLogoLookup.httpsPageURL("http://sender.example/pfad?x=1")?
            .absoluteString == "https://sender.example/pfad?x=1")
        // Nothing usable stays nothing (no invented URL).
        #expect(RadioLogoLookup.httpsPageURL(nil) == nil)
        #expect(RadioLogoLookup.httpsPageURL("   ") == nil)
        #expect(RadioLogoLookup.httpsPageURL("ftp://sender.example") == nil)
    }
}
