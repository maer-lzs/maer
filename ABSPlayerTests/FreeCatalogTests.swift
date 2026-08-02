// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Foundation
import Testing
@testable import ABSPlayer

/// 0714d26: pure free-catalog mappers — language filter, duration parsing,
/// track building (cumulative offsets), archive file selection, decoders
/// against the wire corpus contract.
struct FreeCatalogTests {

    @Test("Language filter: mapped codes filter; exotic/no-match keeps everything")
    func languageFilter() {
        func book(_ lang: String) -> LibriVoxBook {
            LibriVoxBook(id: "1", title: "T", language: lang, totaltimesecs: nil,
                         url_iarchive: nil, url_librivox: nil, url_rss: nil,
                         authors: nil, sections: nil)
        }
        let books = [book("German"), book("English"), book("French")]
        #expect(FreeCatalog.filterByLanguages(books, codes: ["de"]).map(\.language) == ["German"])
        #expect(FreeCatalog.filterByLanguages(books, codes: ["de", "en"]).count == 2)
        // Exotic locale (no mapping) → unfiltered, an empty row would be worse.
        #expect(FreeCatalog.filterByLanguages(books, codes: ["xx"]).count == 3)
        // Mapped but zero hits → unfiltered fallback (same principle).
        #expect(FreeCatalog.filterByLanguages(books, codes: ["ja"]).count == 3)
        // bb6e509 Verdacht 2 explizit: de with ZERO German hits (LibriVox
        // ships few new German books) must fall back to unfiltered — the
        // row shows English instead of vanishing.
        let noGerman = [book("English"), book("French")]
        #expect(FreeCatalog.filterByLanguages(noGerman, codes: ["de"]).count == 2)
    }

    @Test("Durations: SS / MM:SS / H:MM:SS / plain seconds")
    func durations() {
        #expect(FreeCatalog.seconds("45") == 45)
        #expect(FreeCatalog.seconds("8:26") == 506)
        #expect(FreeCatalog.seconds("1:12:14") == 4334)
        #expect(FreeCatalog.seconds("") == nil)
        #expect(FreeCatalog.seconds(nil) == nil)
    }

    @Test("LibriVox tracks: cumulative offsets, url-less sections skipped")
    func librivoxTracks() {
        let sections: [LibriVoxBook.Section] = [
            .init(section_number: "1", title: "One", listen_url: "https://a/1.mp3", playtime: "60"),
            .init(section_number: "2", title: "Text only", listen_url: nil, playtime: "999"),
            .init(section_number: "3", title: "Two", listen_url: "https://a/2.mp3", playtime: "2:00"),
        ]
        let tracks = FreeCatalog.tracks(from: sections)
        #expect(tracks.count == 2)
        #expect(tracks[0].startOffset == 0)
        #expect(tracks[1].startOffset == 60)
        #expect(tracks[1].duration == 120)
    }

    @Test("Archive tracks: 64kb rendition only, name order, encoded URLs")
    func archiveTracks() {
        let files: [ArchiveFile] = [
            .init(name: "b_02_64kb.mp3", length: "1:00", title: nil),
            .init(name: "b_01_64kb.mp3", length: "30", title: nil),
            .init(name: "b_01.ogg", length: "30", title: nil),
            .init(name: "cover.jpg", length: nil, title: nil),
        ]
        let tracks = FreeCatalog.archiveTracks(identifier: "item x", files: files)
        #expect(tracks.count == 2)
        #expect(tracks[0].contentUrl.hasSuffix("/b_01_64kb.mp3"))
        #expect(tracks[0].contentUrl.contains("item%20x"))
        #expect(tracks[1].startOffset == 30)
    }

    @Test("Identifier + cover derivation from url_iarchive")
    func identifiers() {
        #expect(FreeCatalog.iarchiveIdentifier(from: "https://www.archive.org/details/art_of_war_librivox")
                == "art_of_war_librivox")
        #expect(FreeCatalog.iarchiveIdentifier(from: nil) == nil)
        #expect(FreeCatalog.archiveCoverURL(identifier: "abc")?.absoluteString
                == "https://archive.org/services/img/abc")
    }

    @Test("Decoders throw on the wire corpus (no silent empty rows)")
    func decodersThrow() throws {
        for (name, ext) in [("portal", "html"), ("half", "json"), ("empty", "json")] {
            let data = try CorpusFixture.data(name, ext: ext, subdirectory: "WireCorpus")
            #expect(throws: (any Error).self) { _ = try LibriVoxClient.decodeFeed(data) }
            #expect(throws: (any Error).self) { _ = try ArchiveOrgClient.decodePopular(data) }
            #expect(throws: (any Error).self) { _ = try JamendoClient.decodeTracks(data) }
        }
    }
}
#endif
