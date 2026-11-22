// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The Musopen page in the order of composer and work, the single parts of
/// an orchestra recording (one instrument, one microphone) at its end. And
/// the map of the areas names Musopen among what needs no account.
struct MusopenOrderTests {
    @Test("a single part is one instrument or one microphone of a recording; a work is none")
    func singleParts() {
        for title in ["1st violin B 02", "2nd violin F 03", "Viola B 02", "Celli F 01", "DB 02 L",
                      "Bassoon 01", "Contra basson 02", "Clarinet 03", "Flute 02 R", "Horn 03 L",
                      "Oboe 02 L", "Timpani 03 R", "Trumpet 02", "Decca 02 C", "Premix 03.L",
                      "Surr 02 R", "Wide 03 L"] {
            #expect(MusopenOrder.isSinglePart(title), "\(title)")
        }
        for title in ["Prelude Op. 28 no. 4", "Brahms Clarinet Trio 2", "Horn Concerto No. 2 in E flat major",
                      "Grieg - Peer Gynt Suite No. 1, Op. 46 - I. Morning Mood (Musopen Symphony)",
                      "Violin Sonata", "Nocturne Op. 9 no. 2 in E flat major", "Flute"] {
            #expect(!MusopenOrder.isSinglePart(title), "\(title)")
        }
    }

    @Test("the composer is the family name the source states, else the name before the dash of the title")
    func composerKey() {
        #expect(MusopenOrder.composerKey(author: "Wolfgang Amadeus Mozart", title: "1st violin B 02") == "mozart")
        #expect(MusopenOrder.composerKey(author: "Mozart", title: "x") == "mozart")
        #expect(MusopenOrder.composerKey(author: "Antonín Dvořák", title: "x") == "dvorak")
        #expect(MusopenOrder.composerKey(author: "(See Musopen for author information)",
                                         title: "Antonin Dvorak - carnival overture, op. 92") == "dvorak")
        #expect(MusopenOrder.composerKey(author: "Composer: Alexander Glazunov (Глазунов, Александр)",
                                         title: "x") == "glazunov")
        #expect(MusopenOrder.composerKey(author: nil, title: "Haydn - String Quartet") == "haydn")
        #expect(MusopenOrder.composerKey(author: nil, title: "Nocturne") == "")
        // The name before the dash of the title comes first: the source
        // names the performers in its artist field as often as the composer.
        #expect(MusopenOrder.composerKey(author: "Musopen Symphony Orchestra",
                                         title: "Grieg - Peer Gynt Suite No. 1, Op. 46") == "grieg")
        // A performer, a sentence or a note is no composer.
        #expect(MusopenOrder.composerKey(author: "European Archives", title: "A Midsummer Night's Dream") == "")
        #expect(MusopenOrder.composerKey(author: "The Modena Chamber Orchestra", title: "x") == "")
        #expect(MusopenOrder.composerKey(author: "Unknown authorUnknown author", title: "x") == "")
        #expect(MusopenOrder.composerKey(
            author: "Composed by Claude Joseph Rouget de Lisle; arranged by Hector Berlioz in April 1792.",
            title: "Francia") == "")
        #expect(MusopenOrder.composerKey(author: "Robert Schumann (1810-1856) (see Musopen for performance authors)",
                                         title: "x") == "schumann")
        // A work before the dash is no name; the artist field speaks then.
        #expect(MusopenOrder.composerKey(author: "Mozart", title: "Symphony No. 5 in C minor - I. Allegro") == "mozart")
    }

    @Test("composer, then work; recordings without a composer after them; the single parts last")
    func order() {
        let items: [(String, String?)] = [
            ("1st violin B 02", "Wolfgang Amadeus Mozart"),
            ("Symphony No. 40", "Mozart"),
            ("A Midsummer Night's Dream", "European Archive"),
            ("Ballade No. 3", "Frédéric Chopin"),
            ("Viola B 02", "Mozart"),
            ("Antonin Dvorak - carnival overture, op. 92", "(See Musopen for author information)"),
            ("Ballade No. 1", "Chopin"),
        ]
        let ordered = MusopenOrder.ordered(items, title: { $0.0 }, composer: { $0.1 }).map(\.0)
        #expect(ordered == ["Ballade No. 1", "Ballade No. 3", "Antonin Dvorak - carnival overture, op. 92",
                            "Symphony No. 40", "A Midsummer Night's Dream", "1st violin B 02", "Viola B 02"])
    }

    @Test("the page shows its recordings in that order and reads every answer when it opens", .needsTheSources)
    func pageOrders() throws {
        let page = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Music/MusopenViews.swift"), encoding: .utf8))
        #expect(page.contains("MusopenOrder.ordered(items, title: { $0.title }, composer: { $0.author })"))
        #expect(page.contains("while cursor != nil"), "the page reads on only while scrolling")
    }

    @Test("the map of the areas names Musopen among what needs no account, in both languages", .needsTheSources)
    func theMapNamesMusopen() throws {
        let card = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/SourceMapCard.swift"), encoding: .utf8))
        #expect(card.contains("Text(\"No account needed: LibriVox, radio plays, netlabels, old records, Musopen\")"))
        let catalog = try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Localizable.xcstrings"), encoding: .utf8)
        #expect(catalog.contains("\"value\" : \"Ohne Konto: LibriVox, Hörspiele, Netlabels, alte Schallplatten, Musopen\""))
    }
}
#endif
