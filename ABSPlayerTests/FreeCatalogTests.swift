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
            .init(name: "b_02_64kb.mp3", length: "1:00", title: nil, format: nil),
            .init(name: "b_01_64kb.mp3", length: "30", title: nil, format: nil),
            .init(name: "b_01.ogg", length: "30", title: nil, format: nil),
            .init(name: "cover.jpg", length: nil, title: nil, format: nil),
        ]
        let tracks = FreeCatalog.archiveTracks(identifier: "item x", files: files)
        #expect(tracks.count == 2)
        #expect(tracks[0].contentUrl.hasSuffix("/b_01_64kb.mp3"))
        #expect(tracks[0].contentUrl.contains("item%20x"))
        #expect(tracks[1].startOffset == 30)
    }

    @Test("f374330: ISO-639-3 clause — variants ORed, unmapped codes drop, none maps → nil")
    func languageClause() {
        #expect(FreeCatalog.archiveLanguageClause(codes: ["de"])
                == "(language:\"deu\" OR language:\"ger\")")
        #expect(FreeCatalog.archiveLanguageClause(codes: ["de", "en"])
                == "(language:\"deu\" OR language:\"ger\" OR language:\"eng\")")
        #expect(FreeCatalog.archiveLanguageClause(codes: ["xx"]) == nil)
        #expect(FreeCatalog.archiveLanguageClause(codes: []) == nil)
    }

    @Test("Identifier + cover derivation from url_iarchive")
    func identifiers() {
        #expect(FreeCatalog.iarchiveIdentifier(from: "https://www.archive.org/details/art_of_war_librivox")
                == "art_of_war_librivox")
        #expect(FreeCatalog.iarchiveIdentifier(from: nil) == nil)
        #expect(FreeCatalog.archiveCoverURL(identifier: "abc")?.absoluteString
                == "https://archive.org/services/img/abc")
    }

    @Test("7edb21b: discover mix — moderate interleave, cap respected, leftovers trail")
    func discoverMixing() {
        let recs = ["r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8"]
        let books = ["b1", "b2", "b3"]
        let mixed = FreeCatalog.discoverMix(recommendations: recs, books: books)
        // After every 4th recommendation one book; order preserved.
        let flat = mixed.map { $0.rec ?? $0.book ?? "?" }
        #expect(flat == ["r1", "r2", "r3", "r4", "b1", "r5", "r6", "r7", "r8", "b2", "b3"])
        // No books → pure recommendations; no recommendations → books only.
        #expect(FreeCatalog.discoverMix(recommendations: recs, books: [String]()).count == recs.count)
        #expect(FreeCatalog.discoverMix(recommendations: [String](), books: books).count == books.count)
    }

    @Test("b395e5f: itunes:image extraction — one tag scan, no full parse")
    func itunesImage() {
        let rss = """
        <?xml version="1.0"?><rss><channel><title>X</title>
        <itunes:image href="https://www.archive.org/download/x/cover.jpg" />
        </channel></rss>
        """
        #expect(FreeCatalog.extractItunesImage(Data(rss.utf8))
                == "https://www.archive.org/download/x/cover.jpg")
        // Missing tag, malformed href, non-http scheme → nil (thumb stays).
        #expect(FreeCatalog.extractItunesImage(Data("<rss></rss>".utf8)) == nil)
        #expect(FreeCatalog.extractItunesImage(Data("<itunes:image nohref='x'/>".utf8)) == nil)
        #expect(FreeCatalog.extractItunesImage(Data("<itunes:image href=\"ftp://x\"/>".utf8)) == nil)
    }

    @Test("aed5d25: artifact deny — meta items drop, real books pass")
    func artifactFilter() {
        #expect(FreeCatalog.isArtifactDoc(identifier: "cdcoverartarchive", title: nil))
        #expect(FreeCatalog.isArtifactDoc(identifier: "librivox_test_item", title: nil))
        #expect(FreeCatalog.isArtifactDoc(identifier: "x", title: "The Complete Collection Vol 1"))
        #expect(FreeCatalog.isArtifactDoc(identifier: "pride_m4b_bundle", title: nil))
        #expect(!FreeCatalog.isArtifactDoc(identifier: "art_of_war_librivox", title: "The Art of War"))
        #expect(!FreeCatalog.isArtifactDoc(identifier: nil, title: nil))
    }

    @Test("aed5d25: track-count plausibility bounds")
    func trackPlausibility() {
        #expect(FreeCatalog.trackCountPlausible(1))
        #expect(FreeCatalog.trackCountPlausible(200))
        #expect(!FreeCatalog.trackCountPlausible(0))
        #expect(!FreeCatalog.trackCountPlausible(201))
    }

    @Test("3ac9183: creator String OR Array — both decode, first leads, join for detail")
    func creatorArray() throws {
        let data = try CorpusFixture.data("creator-array", ext: "json", subdirectory: "WireCorpus")
        let docs = try ArchiveOrgClient.decodePopular(data)
        #expect(docs.count == 2)
        // Array case: composer first for rows, everyone joined for the detail.
        #expect(docs[0].creator?.first == "Sergei Rachmaninoff")
        #expect(docs[0].creator?.joined == "Sergei Rachmaninoff, Philadelphia Orchestra, Eugene Ormandy")
        #expect(docs[0].title?.first == "Piano Concerto No. 2")
        // String case unchanged.
        #expect(docs[1].creator?.first == "Sun Tzu")
        // Any OTHER type still throws (wire discipline unchanged).
        let broken = Data("""
        {"response":{"docs":[{"identifier":"x","creator":42}]}}
        """.utf8)
        #expect(throws: (any Error).self) { _ = try ArchiveOrgClient.decodePopular(broken) }
    }

    @Test("37e4a23: format chain — VBR-only georgeblood plays, FLAC/thumb skipped, 64kb still first")
    func formatChain() throws {
        let data = try CorpusFixture.data("georgeblood-vbr", ext: "json", subdirectory: "WireCorpus")
        let meta = try JSONDecoder().decode(ArchiveOrgClient.MetadataResponse.self, from: data)
        let tracks = FreeCatalog.archiveTracks(identifier: "78_der-rosenkavalier_gbia0000083b",
                                               files: meta.files ?? [])
        // VBR MP3 group wins (no 64/128kb rendition exists); FLAC + thumb drop.
        #expect(tracks.count == 2)
        // Real georgeblood names: spaces, brackets, hyphens — hard-encoded,
        // nothing but unreserved characters survives raw.
        let url = try #require(tracks.first?.contentUrl)
        #expect(url == "https://archive.org/download/78_der-rosenkavalier_gbia0000083b/Der%20Rosenkavalier%20-%20Richard%20Strauss%20-%20Walzerfolge%20%28Teil%201%29-restored.mp3")
        #expect(URL(string: url) != nil)
        // 64kb stays the FIRST preference when present.
        let mixed = [
            ArchiveFile(name: "a_vbr.mp3", length: "10", title: nil, format: "VBR MP3"),
            ArchiveFile(name: "a_64kb.mp3", length: "10", title: nil, format: "64Kbps MP3"),
        ]
        #expect(FreeCatalog.preferredAudioFiles(mixed).map(\.name) == ["a_64kb.mp3"])
        // No format field at all → legacy 64kb filename fallback.
        let legacy = [ArchiveFile(name: "x_64kb.mp3", length: "5", title: nil, format: nil),
                      ArchiveFile(name: "x.png", length: nil, title: nil, format: nil)]
        #expect(FreeCatalog.preferredAudioFiles(legacy).map(\.name) == ["x_64kb.mp3"])
        // Nothing streamable → empty (plausibility gate at the call site).
        let none = [ArchiveFile(name: "x.flac", length: "5", title: nil, format: "24bit Flac")]
        #expect(FreeCatalog.preferredAudioFiles(none).isEmpty)
    }

    @Test("37e4a23: path-segment encoding — umlauts, apostrophes, brackets, spaces")
    func pathEncoding() {
        #expect(FreeCatalog.encodedPathSegment("Grieg - Solveig's Lied (Solvejgs sang).mp3")
                == "Grieg%20-%20Solveig%27s%20Lied%20%28Solvejgs%20sang%29.mp3")
        #expect(FreeCatalog.encodedPathSegment("Höhle der Löwen.mp3")
                == "H%C3%B6hle%20der%20L%C3%B6wen.mp3")
        #expect(FreeCatalog.encodedPathSegment("plain_64kb.mp3") == "plain_64kb.mp3")
    }

    @Test("5034add: activation hierarchy — master beats feature beats service")
    func activation() {
        #expect(FreeCatalogActivation.effective(master: true, feature: true, service: true))
        #expect(!FreeCatalogActivation.effective(master: false, feature: true, service: true))
        #expect(!FreeCatalogActivation.effective(master: true, feature: false, service: true))
        #expect(!FreeCatalogActivation.effective(master: true, feature: true, service: false))
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
