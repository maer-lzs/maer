// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
@testable import ABSPlayer

/// The OTR title family. Every case below is a REAL name
/// measured at archive.org across eight collections on 09.08.. The patterns
/// differ per series, which is exactly why the rule is conservative.
struct OTRTitleTests {
    @Test("the housekeeping head is cut and the air date is kept")
    func realNamesFromEightCollections() {
        let cases: [(raw: String, title: String, date: String?)] = [
            ("Gunsmoke 52-04-26 (001) Billy the Kid", "Billy the Kid", "1952-04-26"),
            ("YTJD 1948-12-07 000 Milford Brooks III (Dick Powell Audition)",
             "Milford Brooks III (Dick Powell Audition)", "1948-12-07"),
            ("Dragnet_49-06-10_002_Production_2_aka_Homicide",
             "Production 2 aka Homicide", "1949-06-10"),
            ("Richard Diamond 49-05-01 (002) Diamond In the Rough (AFRS)",
             "Diamond In the Rough (AFRS)", "1949-05-01"),
            ("Philip_Marlowe_47-06-12_xxx_Who_Shot_Waldo",
             "Who Shot Waldo", "1947-06-12"),
            // Suspense carries a technical tail: bitrate, size, duration.
            ("Suspense 420617 001 The Burning Court (128-44) 28455 30m00s",
             "The Burning Court", "1942-06-17"),
        ]
        for c in cases {
            let got = FreeCatalog.otrEpisode(fromFileName: c.raw)
            #expect(got.title == c.title, "title of \(c.raw)")
            #expect(got.airDate == c.date, "date of \(c.raw)")
        }
    }

    @Test("without a recognised date nothing is cut (never guess)")
    func conservativeWhenNothingMatches() {
        for raw in ["Billy the Kid", "The Whistler", "Episode Two - Part 1"] {
            let got = FreeCatalog.otrEpisode(fromFileName: raw)
            #expect(got.title == raw)
            #expect(got.airDate == nil)
        }
        // A head WITHOUT a following title is not a head. The name stays.
        let bare = FreeCatalog.otrEpisode(fromFileName: "Gunsmoke 52-04-26 (001)")
        #expect(bare.title == "Gunsmoke 52-04-26 (001)")
    }

    @Test("two-digit years are the 20th century — radio plays predate 2000")
    func twoDigitYears() {
        #expect(FreeCatalog.isoAirDate("52-04-26") == "1952-04-26")
        #expect(FreeCatalog.isoAirDate("420617") == "1942-06-17")
        #expect(FreeCatalog.isoAirDate("19480607") == "1948-06-07")
        #expect(FreeCatalog.isoAirDate("nonsense") == nil)
    }

    @Test("O-P2: the description's repeated heading and its hole are gone")
    func descriptionHeadingAndHole() {
        // The real shape (measured): a centred heading repeating the title,
        // then blank lines, then the text. The author field carries the
        // uploading group. So this is NOT the author line.
        let text = "YOURS TRULY, JOHNNY DOLLAR\n\n\nFor over twelve years, from 1949 …"
        let tidied = FreeCatalog.tidiedDescription(text, title: "Yours Truly, Johnny Dollar - Single Episodes")
        #expect(tidied.hasPrefix("For over twelve years"))
        #expect(!tidied.contains("\n\n\n"))

        // A description that does NOT open with the title keeps every word.
        let other = FreeCatalog.tidiedDescription("A detective drama.\n\nSecond line.",
                                                  title: "Yours Truly, Johnny Dollar")
        #expect(other == "A detective drama.\n\nSecond line.")
    }

    @Test("O-P3: collection housekeeping leaves the work title")
    func collectionSuffixes() {
        // Measured: 12 of the top 25 OTR collections carry such a suffix.
        #expect(FreeCatalog.normalizedCollectionTitle("Yours Truly, Johnny Dollar - Single Episodes")
                == "Yours Truly, Johnny Dollar")
        #expect(FreeCatalog.normalizedCollectionTitle("Our Miss Brooks - 190 Episodes")
                == "Our Miss Brooks")
        #expect(FreeCatalog.normalizedCollectionTitle("CBS Radio Mystery Theater - The Complete Series (1399 episodes)")
                == "CBS Radio Mystery Theater")
        #expect(FreeCatalog.normalizedCollectionTitle("Yours Truly, Johnny Dollar - Single Episodes - Bob Bailey 30 Minute Eps")
                == "Yours Truly, Johnny Dollar")
        // Unknown shapes stay untouched. And a title that would become empty
        // keeps its original (never hand back nothing).
        #expect(FreeCatalog.normalizedCollectionTitle("Dragnet the 50's radio show")
                == "Dragnet the 50's radio show")
        #expect(FreeCatalog.normalizedCollectionTitle("- Single Episodes")
                == "- Single Episodes")
    }
}
#endif
