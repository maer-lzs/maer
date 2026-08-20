// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import ABSPlayer

/// 4e1688d: the sibling stage of the logo chain — the same station appears
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

    /// the owner's actual case, with the measured numbers.
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
    /// logo of "Laut.FM Chillharmonie" — and a wrong logo is worse than a
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

    /// The strongest QUALIFYING sibling wins — votes still rank, they just no
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

    /// The search asks for the BRAND, not the sub-channel — "Sunshine Live -
    /// Techno" would find no siblings under its full name.
    @Test func theSearchAsksForTheBrandStem() {
        #expect(RadioLogoLookup.brandStem(of: "Sunshine Live - Techno") == "Sunshine Live")
        #expect(RadioLogoLookup.brandStem(of: "bigFM Deutschland") == "bigFM Deutschland")
        let url = RadioLogoLookup.siblingSearchURL(name: "Hit Radio FFH - 80er",
                                                   mirror: "https://de1.api.radio-browser.info")
        #expect(url?.query?.contains("name=Hit%20Radio%20FFH") == true
                || url?.query?.contains("name=Hit+Radio+FFH") == true)
    }

    /// Measured against the REAL page: bigFM's icon sits on a foreign CDN
    /// (`file.atsw.de`), not on the station's own domain. the reviewer suspected the
    /// absolute foreign address as the reason the homepage stage broke off —
    /// this fence holds the answer that it does not.
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
}
