// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// Who the composer of a Musopen recording is has one answer for the
/// page's order, the drawn cover (with its colour and letter) and the
/// player (`MusopenOrder.composer`). A field that is no name does not
/// become the composer. The work line stays the whole title.
struct MusopenComposerTests {
    /// The forms of the artist field as the stock states them, measured
    /// over the categories on 23.11.2026.
    @Test("a field that is no name does not become the composer; a labelled name does")
    func fieldForms() {
        let cases: [(String?, String, String?)] = [
            ("(See Musopen for author information)", "Isaac Albeniz - suite espanola op. 47 - leyenda", "Isaac Albeniz"),
            ("(See Musopen for author information)", "Jacques Ibert- cinq pieces en trio", nil),
            ("Unknown authorUnknown author", "Nocturne in E flat", nil),
            ("Musopen Symphony Orchestra", "Symphony No. 5 in C minor", nil),
            ("The Modena Chamber Orchestra", "Concerto", nil),
            ("European Archives", "A Midsummer Night's Dream", nil),
            ("Composer: Frédéric Chopin; Performer: Paul Pitman", "Nocturne Op. 9 No. 2", "Frédéric Chopin"),
            ("Performers: Ensemble Morales\n\nComposer: William Byrd (c.1539–1623)", "Mass for Four Voices", "William Byrd"),
            ("J.S. Bach. Performer: Michel Rondeau", "Prelude in C", nil),
            ("Frank Lévy (performer)", "Sonata", nil),
            ("Grieg, Edvard; Musopen Symphony Orchestra", "Peer Gynt", "Edvard Grieg"),
            ("Robert Schumann (1810-1856) (see Musopen for performance author information)", "Kinderszenen", "Robert Schumann"),
            ("Johann Sebastian Bach", "Bach, J S - Goldberg Variations, BWV988 - 01. Aria", "Johann Sebastian Bach"),
            (nil, "Bach, J S - Goldberg Variations", "J S Bach"),
        ]
        for (field, title, expected) in cases {
            #expect(MusopenOrder.composer(author: field, title: title) == expected, "\(field ?? "nil") | \(title)")
        }
    }

    @Test("the order's key is the family name of the same answer")
    func theKeyFollows() {
        #expect(MusopenOrder.composerKey(author: "Composer: Frédéric Chopin; Performer: Paul Pitman", title: "x") == "chopin")
        #expect(MusopenOrder.composerKey(author: "J.S. Bach. Performer: Michel Rondeau", title: "x") == "")
        #expect(MusopenOrder.composerKey(author: "Performers: Ensemble Morales\n\nComposer: William Byrd (c.1539–1623)", title: "x") == "byrd")
    }

    @Test("the cover's composer, colour and letter come from the answer; the work line stays the whole title")
    func theCoverFollows() {
        let title = "Isaac Albeniz - suite espanola op. 47 - leyenda"
        let lines = MusopenCoverArt.lines(title: title, composer: "(See Musopen for author information)")
        #expect(lines.composer == "Isaac Albeniz")
        #expect(lines.work == title, "the work line stays as it is")
        #expect(MusopenCoverArt.initial(composer: lines.composer, title: lines.work) == "A")
        let pitman = MusopenCoverArt.lines(title: "Nocturne", composer: "Composer: Frédéric Chopin; Performer: Paul Pitman")
        let gurevich = MusopenCoverArt.lines(title: "Waltz", composer: "Composer: Frédéric Chopin; Performer: Olga Gurevich")
        #expect(MusopenCoverArt.colourIndices(composer: pitman.composer) == MusopenCoverArt.colourIndices(composer: gurevich.composer),
                "one composer, one colour, whoever plays")
        #expect(MusopenCoverArt.lines(title: "Nocturne", composer: "Unknown authorUnknown author").composer == nil)
    }

    @Test("the player's line names the composer of a Musopen recording; another source keeps its own")
    func thePlayerFollows() {
        let note = "(See Musopen for author information)"
        let title = "Isaac Albeniz - suite espanola op. 47 - leyenda"
        #expect(MusopenOrder.artistLine(itemId: MusopenCatalog.prefix + "1", title: title, author: note) == "Isaac Albeniz")
        #expect(MusopenOrder.artistLine(itemId: MusopenCatalog.prefix + "2", title: "Trio", author: note) == note,
                "without a composer the line keeps what the source states")
        #expect(MusopenOrder.artistLine(itemId: FreeCatalog.archivePrefix + "x", title: title, author: note) == note)
    }

    @Test("the player asks the rule for its line", .needsTheSources)
    func thePlayerAsks() throws {
        let model = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/PlayerViewModel.swift"), encoding: .utf8))
        #expect(model.contains("MusopenOrder.artistLine(itemId:"))
    }
}
#endif
