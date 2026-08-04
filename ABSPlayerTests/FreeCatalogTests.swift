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

    @Test("31974ef: importer state — failed stays at ITS book, cancel is neutral, busy refuses")
    @MainActor
    func importerState() async throws {
        let importer = LibriVoxImporter.shared
        importer.cancel()   // clean slate
        #expect(!importer.busy)
        // A book without downloadable sections fails WITHOUT network — the
        // terminal state keeps the book id (foreign sheets gate on it).
        let empty = LibriVoxBook(id: "42", title: "T", language: nil,
                                 totaltimesecs: nil, url_iarchive: nil,
                                 url_librivox: nil, url_rss: nil,
                                 authors: nil, sections: [])
        importer.start(book: empty, itemId: "lv:42", libraryId: "L", folderId: "F")
        // The run task is async — poll briefly for the terminal phase.
        for _ in 0..<50 {
            if case .failed = importer.phase { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .failed = importer.phase else {
            Issue.record("expected .failed, got \(importer.phase)"); return
        }
        #expect(importer.activeBookId == "lv:42")
        #expect(!importer.busy)
        // Retry path: reset returns to a clean idle.
        importer.reset()
        #expect(importer.activeBookId == nil)
        if case .idle = importer.phase {} else { Issue.record("reset must yield idle") }
        // Cancel is ALWAYS neutral, never an error.
        importer.cancel()
        if case .idle = importer.phase {} else { Issue.record("cancel must yield idle") }
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

/// 938aebc/ea6e002: the free-audiobook row's SELECTION (per-language
/// popularity, interleaved) and the card's runtime line.
struct FreeCatalogSelectionTests {
    @Test("runtime strings parse tolerantly; nonsense stays nil")
    func runtimeParsing() {
        #expect(FreeCatalog.runtimeSeconds("4:55:03") == Double(4 * 3600 + 55 * 60 + 3))
        #expect(FreeCatalog.runtimeSeconds("2:50") == Double(2 * 60 + 50))
        // Measured on archive.org: a dot instead of the last colon occurs.
        #expect(FreeCatalog.runtimeSeconds("16:31.09") == Double(16 * 3600 + 31 * 60 + 9))
        // A wrong duration is worse than none.
        #expect(FreeCatalog.runtimeSeconds(nil) == nil)
        #expect(FreeCatalog.runtimeSeconds("") == nil)
        #expect(FreeCatalog.runtimeSeconds("unknown") == nil)
        #expect(FreeCatalog.runtimeSeconds("1:75:00") == nil)   // minutes > 59
        #expect(FreeCatalog.runtimeSeconds("12") == nil)        // no separator
        #expect(FreeCatalog.runtimeSeconds("0:00") == nil)      // zero is no runtime
    }

    @Test("per-language results interleave fairly, dedupe, and respect the limit")
    func interleave() {
        let de = ["de1", "de2", "de3"]
        let en = ["en1", "en2", "en3", "en4"]
        let out = FreeCatalog.interleaveByLanguage([de, en], limit: 6) { $0 }
        // Fair round-robin: no language may open the row alone.
        #expect(out == ["de1", "en1", "de2", "en2", "de3", "en3"])
        // The limit caps, the leftovers of the longer list trail.
        #expect(FreeCatalog.interleaveByLanguage([de, en], limit: 8) { $0 }.count == 7)
        // Same identifier in two languages appears once.
        #expect(FreeCatalog.interleaveByLanguage([["x", "a"], ["x", "b"]], limit: 4) { $0 }
                == ["x", "a", "b"])
        // An empty language never blocks the round.
        #expect(FreeCatalog.interleaveByLanguage([[], en], limit: 2) { $0 } == ["en1", "en2"])
        #expect(FreeCatalog.interleaveByLanguage([[String]](), limit: 3) { $0 }.isEmpty)
    }

    @Test("fbcff9f: the ring reads the import phase; terminal states end it")
    func ringFraction() {
        #expect(LibriVoxImporter.ringFraction(.downloading(section: 1, of: 4)) == 0.25)
        #expect(LibriVoxImporter.ringFraction(.downloading(section: 4, of: 4)) == 1)
        // Guard against a nonsense total instead of dividing by zero.
        #expect(LibriVoxImporter.ringFraction(.downloading(section: 1, of: 0)) == -1)
        // Indeterminate phases keep the ring spinning honestly.
        #expect(LibriVoxImporter.ringFraction(.checking) == -1)
        #expect(LibriVoxImporter.ringFraction(.uploading) == -1)
        // No frozen ring: cancel/idle and every terminal state end it.
        #expect(LibriVoxImporter.ringFraction(.idle) == nil)
        #expect(LibriVoxImporter.ringFraction(.done) == nil)
        #expect(LibriVoxImporter.ringFraction(.duplicate(existingTitle: "X")) == nil)
        #expect(LibriVoxImporter.ringFraction(.failed("x")) == nil)
    }

    @Test("b81949f: runtime from the item file list — largest format group wins")
    func runtimeFromFiles() {
        // The measured shape: only ONE derivative set carries lengths, the
        // others ship without. Ogg and MP3 both complete ⇒ same total.
        let files: [(format: String?, length: String?)] = [
            (format: "128Kbps MP3", length: "1573.21"),
            (format: "128Kbps MP3", length: "1573.00"),
            (format: "VBR MP3", length: nil),
            (format: "64Kbps MP3", length: nil),
            (format: "JPEG", length: nil),
        ]
        #expect(FreeCatalog.runtimeSeconds(fromFiles: files) == 3146.21)
        // Nothing usable ⇒ nil (and the caller must not book that as a
        // finding if the fetch itself failed — 95c5c16 rule).
        #expect(FreeCatalog.runtimeSeconds(fromFiles: [(format: "JPEG", length: nil)]) == nil)
        #expect(FreeCatalog.runtimeSeconds(fromFiles: []) == nil)
        // "MM:SS" lengths occur on some derivatives.
        #expect(FreeCatalog.fileLength("2:30") == 150)
        #expect(FreeCatalog.fileLength("1573.21") == 1573.21)
        #expect(FreeCatalog.fileLength("nonsense") == nil)
    }

    @Test("b81949f: the shared resolution cache never stores a FAILED lookup")
    func resolutionCacheRule() {
        let suite = "resolution-cache-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ResolutionCacheStore<Double>(key: "testRuntimes")

        #expect(store.store(.found(1234), for: "a", defaults: defaults))
        #expect(store.store(.absent, for: "b", defaults: defaults))
        // The rule that cost every radio logo once: a failure is not a finding.
        #expect(!store.store(.failed, for: "c", defaults: defaults))

        let loaded = store.load(defaults: defaults)
        #expect(loaded["a"] == 1234)
        #expect(loaded["b"] == Double?.none)   // known-absent, cached
        #expect(loaded["c"] == nil)            // never stored at all
        #expect(loaded.count == 2)

        // TTLs: the negative expires earlier than the positive.
        let later = Date().addingTimeInterval(8 * 24 * 3600)
        let afterNegativeTTL = store.load(defaults: defaults, now: later)
        #expect(afterNegativeTTL["a"] == 1234)
        #expect(afterNegativeTTL.keys.contains("b") == false)
    }

    @Test("b4fdc36: the cover-cache cap adapts to free space, within bounds")
    func adaptiveCacheCap() {
        let mb: Int64 = 1024 * 1024
        // Roomy device: 5 % of 40 GB = 2 GB ⇒ clamped to the 500 MB ceiling.
        #expect(ImageCache.cacheCapBytes(freeBytes: 40 * 1024 * mb) == 500 * mb)
        // Middle ground: 5 % of 6 GB ≈ 307 MB — used as is.
        let sixGB = 6 * 1024 * mb
        #expect(ImageCache.cacheCapBytes(freeBytes: sixGB) == Int64(Double(sixGB) * 0.05))
        // Nearly full device: the floor keeps the cache usable.
        #expect(ImageCache.cacheCapBytes(freeBytes: 500 * mb) == 150 * mb)
        #expect(ImageCache.cacheCapBytes(freeBytes: 0) == 150 * mb)
        // Nonsense input cannot produce a negative cap.
        #expect(ImageCache.cacheCapBytes(freeBytes: -1) == 150 * mb)
        // The old fixed value sits between floor and ceiling — the change is
        // an ADJUSTMENT, not a new regime.
        #expect(ImageCache.cacheCapBytes(freeBytes: 40 * 1024 * mb) > 200 * mb)
    }

    @Test("the junk meta item stays filtered (the reviewer's Librivox M4b collection)")
    func junkStaysFiltered() {
        #expect(FreeCatalog.isArtifactDoc(identifier: "librivox_m4b_collection",
                                          title: "Librivox M4b Collection Audiobooks Main"))
    }
}

/// c125ccd: the feed's CHANNEL artwork — read from the head, never from an
/// episode (the first episode's cover must not masquerade as the show's).
struct FeedArtworkLookupTests {
    @Test("itunes:image on channel level wins; the episode image never does")
    func channelBeatsEpisode() {
        let head = """
        <rss><channel><title>hr2 Hörspiel</title>
        <itunes:image href="https://static.hr.de/podcast_bilder/hr2_Hoerspiel.jpg"/>
        <item><title>Folge</title>
        <itunes:image href="https://cdn.example/episode-cover.jpg"/></item>
        """
        #expect(FeedArtworkLookup.channelImageURL(fromHead: head)?.absoluteString
                == "https://static.hr.de/podcast_bilder/hr2_Hoerspiel.jpg")
    }

    @Test("an EPISODE-only image is not the show's artwork")
    func episodeOnlyIsNoHit() {
        let head = """
        <rss><channel><title>Feed</title>
        <item><itunes:image href="https://cdn.example/episode.jpg"/></item>
        """
        #expect(FeedArtworkLookup.channelImageURL(fromHead: head) == nil)
    }

    @Test("plain RSS <image><url> is accepted; escaped ampersands survive")
    func rssImageAndEscaping() {
        let rss = """
        <rss><channel><image><url>https://img.br.de/cover.jpeg?fm=jpg&amp;w=1800</url></image>
        <item></item>
        """
        #expect(FeedArtworkLookup.channelImageURL(fromHead: rss)?.absoluteString
                == "https://img.br.de/cover.jpeg?fm=jpg&w=1800")
        // Single quotes and attribute order vary between broadcasters.
        let single = "<channel><itunes:image type='image/jpeg' href='https://orf.at/c.jpg'/>"
        #expect(FeedArtworkLookup.channelImageURL(fromHead: single)?.absoluteString
                == "https://orf.at/c.jpg")
    }

    @Test("no image, non-http and junk stay nil (a wrong cover is worse than none)")
    func misses() {
        #expect(FeedArtworkLookup.channelImageURL(fromHead: "<rss><channel><title>x</title>") == nil)
        #expect(FeedArtworkLookup.channelImageURL(fromHead: "") == nil)
        #expect(FeedArtworkLookup.channelImageURL(
            fromHead: "<channel><itunes:image href=\"javascript:alert(1)\"/>") == nil)
        #expect(FeedArtworkLookup.channelImageURL(
            fromHead: "<channel><itunes:image/>") == nil)
    }
}

/// f0b9c8a: container feeds in work order — pure recognition, contiguous
/// blocks, ascending inside, single pieces untouched.
struct PodcastWorkOrderTests {
    private func titles(_ list: [String], newestFirst: Bool = true) -> [String] {
        PodcastWorkOrder.ordered(list, newestFirst: newestFirst) { $0 }
    }

    @Test("part patterns of the real feeds are recognized; plain titles are not")
    func recognition() {
        #expect(PodcastWorkOrder.part(fromTitle: "Die drei Stigmata (2/2)")?.index == 2)
        #expect(PodcastWorkOrder.part(fromTitle: "Die drei Stigmata (2/2)")?.total == 2)
        #expect(PodcastWorkOrder.part(fromTitle: "Unearthing 1/8")?.index == 1)
        #expect(PodcastWorkOrder.part(fromTitle: "Kummer aller Art – Teil 3 von 5")?.index == 3)
        #expect(PodcastWorkOrder.part(fromTitle: "Kummer aller Art – Teil 3 von 5")?.total == 5)
        #expect(PodcastWorkOrder.part(fromTitle: "Der Process – Folge 2")?.index == 2)
        #expect(PodcastWorkOrder.part(fromTitle: "Der Process – Folge 2")?.total == nil)
        // Conservative: no pattern, no stem, nonsense totals ⇒ single piece.
        #expect(PodcastWorkOrder.part(fromTitle: "Ein Hörspiel ohne Teile") == nil)
        #expect(PodcastWorkOrder.part(fromTitle: "(1/2)") == nil)
        #expect(PodcastWorkOrder.part(fromTitle: "Werk (5/2)") == nil)
    }

    @Test("the stem folds separators, case and diacritics into one work")
    func stemFolding() {
        let a = PodcastWorkOrder.part(fromTitle: "Mariana Leky: Kummer aller Art (1/3)")
        let b = PodcastWorkOrder.part(fromTitle: "MARIANA LEKY – Kummer aller Art (2/3)")
        #expect(a?.stem == b?.stem)
        // Different works never merge.
        #expect(PodcastWorkOrder.part(fromTitle: "Unearthing (1/8)")?.stem
                != PodcastWorkOrder.part(fromTitle: "Palmer Eldritch (1/2)")?.stem)
    }

    @Test("works become contiguous blocks, ascending inside, at the block's own place")
    func blockOrdering() {
        // The reported feed shape: interleaved, part 2 above part 1.
        let feed = ["Palmer Eldritch (2/2)", "Unearthing (3/8)", "Palmer Eldritch (1/2)",
                    "Einzelstück ohne Teile", "Unearthing (1/8)", "Unearthing (2/8)"]
        #expect(titles(feed) == ["Palmer Eldritch (1/2)", "Palmer Eldritch (2/2)",
                                 "Unearthing (1/8)", "Unearthing (2/8)", "Unearthing (3/8)",
                                 "Einzelstück ohne Teile"])
    }

    @Test("below the density threshold NOTHING moves")
    func densityGate() {
        let mostlySingles = ["Thema A", "Thema B", "Thema C", "Thema D",
                             "Thema E", "Thema F", "Reihe (2/2)", "Reihe (1/2)"]
        #expect(PodcastWorkOrder.partDensity(titles: mostlySingles) < PodcastWorkOrder.containerThreshold)
        #expect(titles(mostlySingles) == mostlySingles)
        // A real container feed sits far above the threshold.
        let container = ["A (1/2)", "A (2/2)", "B (1/3)", "B (2/3)", "B (3/3)", "Solo"]
        #expect(PodcastWorkOrder.partDensity(titles: container) > PodcastWorkOrder.containerThreshold)
    }

    @Test("oldest-first keeps its chronology, blocks still ascend")
    func oldestFirst() {
        let feed = ["Werk (1/2)", "Solo", "Werk (2/2)"]
        #expect(titles(feed, newestFirst: false) == ["Werk (1/2)", "Werk (2/2)", "Solo"])
    }

    @Test("the eyebrow drops only when it repeats the show title")
    func eyebrowRule() {
        #expect(PodcastWorkOrder.eyebrow(author: "ARD HÖRSPIEL", showTitle: "ARD Hörspiel") == nil)
        #expect(PodcastWorkOrder.eyebrow(author: "WDR", showTitle: "ARD Hörspiel") == "WDR")
        // Surfaces mixing shows pass nil and keep their eyebrow.
        #expect(PodcastWorkOrder.eyebrow(author: "WDR", showTitle: nil) == "WDR")
        #expect(PodcastWorkOrder.eyebrow(author: nil, showTitle: "X") == nil)
    }
}
#endif
