// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// One rule names composer, work and performer of a Musopen recording, the
/// same on the tile, the drawn cover, the page and in the player. Witnessed
/// at answers of Commons as they came on 24.11.2026
/// (`Fixtures/ServerAnswers/commons/musopen_composers.json`): a hidden span
/// that doubled "Unknown author", the uploader standing as the artist of
/// La Traviata, the composer in front of the work in the file name.
@MainActor
struct MusopenMetadataTests {
    private func items() throws -> [String: LibraryItem] {
        let page = try MusopenCatalog.page(from: CorpusFixture.data("musopen_composers", ext: "json",
                                                                   subdirectory: "ServerAnswers/commons"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("musopen-\(UUID().uuidString)")
        let provider = FreeCatalogProvider(ablage: Ablage(directory: directory))
        var out: [String: LibraryItem] = [:]
        for recording in page.recordings {
            if let item = provider.remember(recording: recording) { out[String(recording.pageId)] = item }
        }
        return out
    }

    @Test("the artist field as text: no hidden double, no uploader, no Unknown author")
    func artistText() {
        #expect(MusopenCatalog.artistText("Unknown author<span style=\"display: none;\">Unknown author</span>") == nil)
        #expect(MusopenCatalog.artistText("<a href=\"//commons.wikimedia.org/wiki/User:Morn\" title=\"User:Morn\">Morn</a>") == nil)
        #expect(MusopenCatalog.artistText("<bdi><a href=\"https://en.wikipedia.org/wiki/en:Fr%C3%A9d%C3%A9ric_Chopin\">Frédéric Chopin</a></bdi> / <bdi>Frank Levy</bdi>")
                == "Frédéric Chopin; Frank Levy")
        #expect(MusopenCatalog.artistText("The Milan Baroque Soloists") == "The Milan Baroque Soloists")
        #expect(MusopenCatalog.artistText(nil) == nil)
    }

    @Test("La Traviata names Verdi, the uploader names nobody")
    func traviata() throws {
        let item = try #require(try items()["22201798"])
        #expect(item.author == "Giuseppe Verdi")
        #expect(item.media?.metadata?.narratorName == nil, "the uploader stands as performer")
        #expect(item.title == "La Traviata - Act 1 - Libiamo ne' lieti calici")
    }

    @Test("no Unknown author anywhere; the composer in front of the work names it and leaves the work line")
    func unknownAuthorAndComposerInFront() throws {
        let all = try items()
        #expect(all.count == 5, "the fixture read \(all.count) recordings")
        for item in all.values {
            let author = (item.author ?? "").lowercased()
            let performer = (item.media?.metadata?.narratorName ?? "").lowercased()
            #expect(!author.contains("unknown"), "\(item.id): \(author)")
            #expect(!performer.contains("unknown"), "\(item.id): \(performer)")
        }
        let strauss = try #require(all["22204857"])
        #expect(strauss.author == "Johann Strauss" && strauss.title == "Wiener Blut Op. 354")
        let brahms = try #require(all["22218876"])
        #expect(brahms.author == "Brahms" && brahms.title == "Symphony No.3 in F major Op.90 - IV. Allegro")
        let waltz = try #require(all["22269909"])
        #expect(waltz.author == "Strauss" && waltz.title == "Kaiserwalzer", "a family of the stock before a comma")
        let bach = try #require(all["176969623"])
        #expect(bach.author == nil && bach.title == "Komm, süsser Tod, BWV 478", "Komm is no composer")
    }

    @Test("the cover and the player name the composer the tile names")
    func sameEverywhere() throws {
        for item in try items().values {
            let title = item.title
            let lines = MusopenCoverArt.lines(title: title, composer: item.author)
            #expect(lines.composer == item.author, "\(item.id): cover \(lines.composer ?? "-") against tile \(item.author ?? "-")")
            #expect(MusopenOrder.artistLine(itemId: item.id, title: title, author: item.author) == item.author)
        }
    }
}
#endif
