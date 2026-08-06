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
                         authors: nil, sections: nil, genres: nil)
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
                                 authors: nil, sections: [], genres: nil)
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

    /// 48e786d Schritt 0 — der Zaun. Die Genre-Achse war TOTES HOLZ: die API
    /// liefert Genres, aber LibriVoxBook decodierte sie nicht, der Provider
    /// setzte an sieben Stellen nil, die Filterleiste renderte nie. Ein Feld,
    /// das ueberall nil gesetzt wird, faellt beim naechsten Umbau wieder raus,
    /// ohne dass etwas rot wird — dieser Test weist am ECHTEN Korpus nach,
    /// dass mindestens ein Genre bis zum LibraryItem durchkommt.
    @MainActor
    @Test("Genres come through to the LibraryItem (LibriVox corpus)")
    func genresReachTheItem() throws {
        let data = try CorpusFixture.data("librivox-genres", ext: "json", subdirectory: "WireCorpus")
        let books = try LibriVoxClient.decodeFeed(data)
        let withGenres = books.first { !($0.genres ?? []).isEmpty }
        let book = try #require(withGenres, "corpus must contain a book with genres")

        let item = FreeCatalogProvider.shared.remember(book: book)
        let genres = try #require(item.media?.metadata?.genres)
        #expect(!genres.isEmpty)
        // The epoch entry stays in — the axis filters it, not the transport.
        #expect(genres.allSatisfy { !$0.isEmpty })
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

/// 8d49a8e: the two catalog pages' genre axes — chip → chart ids (derived
/// from what the charts CONTAIN) and LibriVox genres → browsable shelves.
struct CatalogGenreAxisTests {
    @Test("radio-play chips map to the measured charts; True Crime stays out")
    func hoerspielChips() {
        let byKey = Dictionary(uniqueKeysWithValues:
            CatalogGenreAxis.hoerspielChips.map { ($0.key, $0.genreIds) })
        // Krimi rides DRAMA: that chart is headed by ARD Radio Tatort and
        // Kriminalhörspiel. True Crime (1488) is documentary — including it
        // would fill the chip with the wrong genre.
        #expect(byKey["krimi"] == [1484])
        #expect(!CatalogGenreAxis.hoerspielChips.contains { $0.genreIds.contains(1488) })
        #expect(byKey["scifi"] == [1485])
        #expect(byKey["komoedie"] == [1486])
        // Literature bundles two charts (plays in Fiction, readings in Books).
        #expect(byKey["literatur"] == [1483, 1482])
        #expect(byKey["kinder"] == [1305])
        // Every chip has at least one chart, keys are unique.
        #expect(CatalogGenreAxis.hoerspielChips.allSatisfy { !$0.genreIds.isEmpty })
        #expect(Set(CatalogGenreAxis.hoerspielChips.map(\.key)).count
                == CatalogGenreAxis.hoerspielChips.count)
    }

    @Test("LibriVox genres fold onto shelves; EPOCHS never become one")
    func librivoxShelves() {
        #expect(CatalogGenreAxis.shelves(forLibriVoxGenres: ["Literary Fiction"]) == ["fiction"])
        #expect(CatalogGenreAxis.shelves(forLibriVoxGenres: ["Detective Fiction"]) == ["crime"])
        // The measured mix: genre AND epoch in one field — the epoch drops,
        // so no year ends up between the shelves.
        #expect(CatalogGenreAxis.shelves(forLibriVoxGenres: ["Published 1800-1900"]).isEmpty)
        #expect(CatalogGenreAxis.shelves(
            forLibriVoxGenres: ["Published 1800-1900", "Science Fiction"]) == ["scifi"])
        #expect(CatalogGenreAxis.isEpoch("Published 1800-1900"))
        #expect(!CatalogGenreAxis.isEpoch("Science Fiction"))
        // Unknown stays unknown — no guessing.
        #expect(CatalogGenreAxis.shelves(forLibriVoxGenres: ["Völlig Unbekannt"]).isEmpty)
        #expect(CatalogGenreAxis.shelves(forLibriVoxGenres: []).isEmpty)
        // Several genres → several shelves, deduped and in BROWSE order
        // (not in the order the feed happened to list them).
        let many = CatalogGenreAxis.shelves(
            forLibriVoxGenres: ["Poetry", "Detective Fiction", "Literary Fiction", "Poetry"])
        #expect(many == ["fiction", "crime", "poetry"])
        // Case and whitespace tolerance (feeds are inconsistent).
        #expect(CatalogGenreAxis.shelves(forLibriVoxGenres: ["  SCIENCE FICTION "]) == ["scifi"])
    }

    @Test("e948444: licence labels stay honest — no blanket 'public domain'")
    func licenceLabels() {
        #expect(FreeCatalog.licenceLabel("http://creativecommons.org/licenses/by-nc-nd/2.5/")
                == "CC BY-NC-ND")
        #expect(FreeCatalog.licenceLabel("http://creativecommons.org/licenses/by-nc-sa/3.0/us/")
                == "CC BY-NC-SA")
        #expect(FreeCatalog.licenceLabel("http://creativecommons.org/licenses/publicdomain/")
                == String(localized: "Public domain"))
        // An unknown form keeps its URL rather than being flattened to "free".
        #expect(FreeCatalog.licenceLabel("https://example.org/some-licence")
                == "https://example.org/some-licence")
        #expect(FreeCatalog.licenceLabel(nil) == nil)
        #expect(FreeCatalog.licenceLabel("") == nil)
    }

    @Test("e948444: the track bound is a parameter — series bundles are the unit there")
    func trackCaps() {
        // The measured reality: Gunsmoke 487, Suspense 911 episodes per item.
        #expect(!FreeCatalog.trackCountPlausible(487))
        #expect(FreeCatalog.trackCountPlausible(487, cap: FreeCatalog.seriesTrackCap))
        #expect(FreeCatalog.trackCountPlausible(911, cap: FreeCatalog.seriesTrackCap))
        // The default guard against ACCIDENTAL bundles is unchanged…
        #expect(FreeCatalog.trackCountPlausible(200))
        #expect(!FreeCatalog.trackCountPlausible(201))
        // …and even the higher bound is not unlimited.
        #expect(!FreeCatalog.trackCountPlausible(1_001, cap: FreeCatalog.seriesTrackCap))
        #expect(!FreeCatalog.trackCountPlausible(0, cap: FreeCatalog.seriesTrackCap))
    }

    @Test("0ce5df3: Gutenberg path filter — readings in, music examples out")
    func gutenbergAudiobookFilter() {
        // Measured on the full stock: readings live under /mp3/ (885) and
        // /<id>-m/ (184); music examples inside scholarly texts under
        // /<id>-h/audio/ (the 6 outliers) would go wrong in a book row.
        #expect(FreeCatalog.isGutenbergAudiobook("https://www.gutenberg.org/files/26471/mp3/26471-01.mp3"))
        #expect(FreeCatalog.isGutenbergAudiobook("https://www.gutenberg.org/files/19942/19942-m/19942-m-01.mp3"))
        #expect(!FreeCatalog.isGutenbergAudiobook("https://www.gutenberg.org/files/68074/68074-h/audio/mus196.mp3"))
        #expect(!FreeCatalog.isGutenbergAudiobook("https://www.gutenberg.org/files/60165/60165-h/audio/p0288.mp3"))
    }

    @Test("bca2d20: LibriVox compilations are excluded — no content twice")
    func libriVoxDuplicateFilter() {
        func doc(_ id: String, title: String = "T", creator: String = "C") -> ArchivePopularDoc {
            ArchivePopularDoc(identifier: id, title: ArchiveStringList([title]),
                              creator: ArchiveStringList([creator]), downloads: 1,
                              runtime: nil, licenseurl: "http://creativecommons.org/licenses/by/4.0/",
                              year: nil, subject: nil)
        }
        // The measured example that slips through NOT collection:librivoxaudio.
        #expect(!FreeCatalog.isNotLibriVoxDuplicate(doc("LibriVoxHorror_2007-2017")))
        #expect(!FreeCatalog.isNotLibriVoxDuplicate(doc("x", title: "Masters of Horror, as read by LibriVox Volunteers")))
        #expect(!FreeCatalog.isNotLibriVoxDuplicate(doc("x", creator: "LibriVox Volunteers")))
        // A genuinely different recording stays.
        #expect(FreeCatalog.isNotLibriVoxDuplicate(doc("weird-tales-lovecraft", title: "Weird Tales from H. P. Lovecraft")))
    }

    @Test("every shelf key in the axis has a display title")
    func shelvesAreComplete() {
        let titles = Set(CatalogGenreAxis.librivoxShelves.map(\.key))
        for shelf in Set(CatalogGenreAxis.librivoxAxis.values) {
            #expect(titles.contains(shelf), "shelf without title: \(shelf)")
        }
    }
    // MARK: - 0b72ac4 A1/A3/A4: Abbruch ist kein Fehler

    /// Der GT-Befund: try? unter async let frass die Unterscheidung — eine
    /// stornierte .task wurde als vier kaputte Quellen verbucht. Die pure
    /// Klassifikation ist der Zaun: Abbruch ⇒ nil (kein failure-Eintrag),
    /// alles andere ⇒ kurzer Grund fuer Log UND Fehlerzeile.
    @Test("Cancellation classifies as nil; real failures carry a tellable reason")
    func failureClassification() {
        #expect(FreeCatalog.failureReason(CancellationError()) == nil)
        #expect(FreeCatalog.failureReason(URLError(.cancelled)) == nil)
        // 27f360b: EIN Blick unterscheidet 429 / HTML-Antwort / Transport.
        #expect(FreeCatalog.failureReason(APIError.http(429, "slow down")) == "HTTP 429")
        #expect(FreeCatalog.failureReason(URLError(.timedOut)) == "URLError \(URLError.Code.timedOut.rawValue)")
        let decode = FreeCatalog.CatalogDecodeError(status: 200, answerPrefix: "<html><head>challenge")
        #expect(FreeCatalog.failureReason(decode) == "decode (HTTP 200): <html><head>challenge")
        #expect(FreeCatalog.failureReason(FreeCatalog.CatalogDecodeError(status: nil, answerPrefix: "x"))
                == "decode (HTTP ?): x")
    }

    // MARK: - Paket 3: EINE Achse fuer zwei Schreibfamilien

    /// 9ef73a4: Gutenbergs LCSH-subjects landen auf DENSELBEN Regalen wie die
    /// LibriVox-Genres — erweitert, nicht daneben gebaut. Die Faelle stammen
    /// aus the reviewer's Messung der 1.124 Audio-Titel.
    @Test("LCSH subjects map onto the shared shelves")
    func lcshShelves() {
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Domestic fiction"]) == ["fiction"])
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Adventure stories"]) == ["adventure"])
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Bildungsromans"]) == ["fiction"])
        // Vier standen woertlich schon in librivoxAxis — dieselbe Achse traegt.
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Love stories"]) == ["romance"])
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Satire"]) == ["comedy"])
        // Facettenschnitt: der Qualifier traegt das Genre.
        #expect(CatalogGenreAxis.shelves(forSubjects: ["England -- Fiction"]) == ["fiction"])
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Paris (France) -- History -- Fiction"])
                == ["fiction", "history"])
        // Kuratier-Listen (bookshelves-Klasse) sind keine Genres: kein Regal.
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Best Books Ever Listings"]).isEmpty)
        #expect(CatalogGenreAxis.shelves(forSubjects: []).isEmpty)
    }

    // MARK: - 11be262 Paket 1/4: Quellen-Aufteilung

    /// the owner's Bedingung "keine Kachel erscheint in beiden Tabs" haelt
    /// STRUKTURELL: feed- und katalogbasierte Quellen sind disjunkte Mengen
    /// EINES enums, und die Kuration verteilt jeden Feed auf genau eine Reihe.
    @Test("Catalog sources split disjointly; every curated feed lands exactly once")
    func catalogSourceSplit() {
        let feed = CatalogSource.allCases.filter(\.isFeedBased)
        let catalog = CatalogSource.allCases.filter { !$0.isFeedBased }
        #expect(!feed.isEmpty && !catalog.isEmpty)
        #expect(Set(feed).isDisjoint(with: Set(catalog)))

        // Jeder kuratierte Feed gehoert zu GENAU einer Feed-Reihe (en aktiv,
        // damit auch die englischen Eintraege verteilt werden).
        let codes = ["de", "en"]
        let all = HoerspielCuration.feeds(forLanguages: codes)
        var seen: [String: Int] = [:]
        for source in feed {
            for entry in source.curatedFeeds(forLanguages: codes) {
                seen[entry.feedURL, default: 0] += 1
            }
        }
        #expect(seen.count == all.count, "every feed must land in a row")
        #expect(seen.values.allSatisfy { $0 == 1 }, "no feed in two rows")

        // Ohne en bleibt OERR uebrig — die anderen Reihen sind leer, nicht kaputt.
        #expect(!CatalogSource.oerr.curatedFeeds(forLanguages: ["de"]).isEmpty)
        #expect(CatalogSource.escapeArtists.curatedFeeds(forLanguages: ["de"]).isEmpty)
        // Katalog-Quellen liefern nie Feeds.
        #expect(CatalogSource.librivox.curatedFeeds(forLanguages: codes).isEmpty)
    }

    // MARK: - c3ab12e: der Zaun gegen den Namensraum-Fehler

    /// Ein Namensraum-Fehler hat the owner aus seinem eigenen Server ausgesperrt:
    /// `gut:`-Kennungen gingen an Audiobookshelf, 41 × 404, CrowdSec las das als
    /// Angriff. Diese Tests werden rot, sobald eine Quelle ihren Namensraum
    /// nicht anmeldet.
    @Test("Jedes Katalog-Praefix ist ein bekannter Namensraum")
    func catalogPrefixesRegistered() {
        for prefix in FreeCatalog.allPrefixes {
            #expect(ItemNamespace.known.contains(prefix),
                    "Namensraum \(prefix) fehlt in ItemNamespace.known")
            let id = prefix + "12345"
            #expect(ItemNamespace.isKnown(id))
            #expect(!ItemNamespace.mayReachLibraryServer(id),
                    "\(prefix) wuerde an den Server gehen — der Ausloeser von c3ab12e")
        }
        // Gutenberg namentlich, weil genau er vergessen wurde.
        #expect(ItemNamespace.known.contains("gut:"))
    }

    @Test("Namensraum ist nur ein FUEHRENDES Schema")
    func namespaceExtraction() {
        #expect(ItemNamespace.of("gut:26471") == "gut:")
        #expect(ItemNamespace.of("sub:album:1") == "sub:")
        #expect(ItemNamespace.of("abc123") == nil)
        #expect(ItemNamespace.of("li_9f3a") == nil)
        // Ein Doppelpunkt MITTEN im Pfad ist kein Namensraum.
        #expect(ItemNamespace.of("/Users/x/a:b.mp3") == nil)
        #expect(ItemNamespace.of(":leer") == nil)
    }

    /// be087e4: der vorige Zaun prueft die REGEL — dieser prueft den WEG.
    /// `mayReachLibraryServer` wurde nur von Tests gelesen, waehrend
    /// `provider(for:)` bei unbekanntem Namensraum weiter den Bibliotheks-
    /// Provider lieferte (11 Aufrufer, darunter die gespeicherte lastId im
    /// PlayerCoordinator). Ein gruener Zaun um nichts.
    @MainActor
    @Test("Der ROUTER selbst gibt fremde Namensraeume nicht an die Bibliothek")
    func routerRefusesUnknownNamespace() {
        let session = AppSession.shared
        // Unbekannte Quelle: weder Bibliothek noch Katalog.
        let unknown = session.provider(for: "neuequelle:42")
        #expect(unknown is UnknownSourceProvider)
        #expect(unknown.coverURL(forItemId: "neuequelle:42") == nil)
        #expect(!unknown.isAvailable)

        // Bekannte Namensraeume gehen weiter an ihre Quelle …
        #expect(session.provider(for: "gut:26471") is FreeCatalogProvider)
        // … und eine kennzeichnungsfreie Id an die Bibliothek (NICHT refused).
        #expect(!(session.provider(for: "li_9f3a") is UnknownSourceProvider))
    }

    @Test("Nur kennzeichnungsfreie Ids duerfen an den Bibliotheks-Server")
    func libraryServerGuard() {
        #expect(ItemNamespace.mayReachLibraryServer("li_9f3a"))
        #expect(!ItemNamespace.mayReachLibraryServer("gut:1"))
        #expect(!ItemNamespace.mayReachLibraryServer("sub:1"))
        // Eine kuenftige Quelle, die noch niemand angemeldet hat: UNBEKANNT und
        // trotzdem kein Server-Aufruf. Das ist der Unterschied zwischen
        // "Liste gepflegt" und "strukturell dicht".
        #expect(!ItemNamespace.isKnown("neuequelle:42"))
        #expect(!ItemNamespace.mayReachLibraryServer("neuequelle:42"))
    }

    // MARK: - 50aefa8: Rechtelage wird nicht geraten

    /// Die Metazeile zeigt NUR, was die Quelle liefert. Fehlt das Jahr, steht
    /// dort keins — georgeblood traegt bei etwa zwei Dritteln der Titel keins,
    /// und ein geratenes Jahr waere bei einer Sammlung ohne Lizenzfeld die
    /// zweite Falschaussage nach der Kapsel.
    /// 12753d8: Schutzfristen sind ortsabhaengig — Schweiz 50, EU 70, USA 100
    /// Jahre fuer Tonaufnahmen. Deshalb darf „gemeinfrei" nur stehen, wo auch
    /// die LAENGSTE Frist abgelaufen ist (Veroeffentlichung bis 1925); dazwischen
    /// nennen wir die Fristen und faellen kein Urteil ueber den Titel.
    /// Gemessen an der Klassik-Reihe: 408 Titel bis 1925, 1021 spaeter, 2842
    /// ganz ohne Jahr.
    @Test("Rechtelage: gemeinfrei nur bei abgelaufener LAENGSTER Frist, sonst Fristen statt Urteil")
    func rightsNote() {
        #expect(FreeCatalog.rightsNote(year: "1925", currentYear: 2026) == .publicDomain)
        #expect(FreeCatalog.rightsNote(year: "1900", currentYear: 2026) == .publicDomain)
        // 1926 ist 2026 der erste Jahrgang, bei dem die US-Frist noch laeuft.
        #expect(FreeCatalog.rightsNote(year: "1926", currentYear: 2026) == .termsApply(year: "1926"))
        // 011827a: die Grenze ALTERT MIT — am 1.1.2027 wird 1926 frei. Die
        // alte Konstante waere fuer immer ein Jahr zu scheu geblieben.
        #expect(FreeCatalog.rightsNote(year: "1926", currentYear: 2027) == .publicDomain)
        // 1947er springen NICHT nach 100 Jahren (110er-Band des MMA) …
        #expect(FreeCatalog.rightsNote(year: "1947", currentYear: 2048) == .termsApply(year: "1947"))
        // … sondern erst 2058.
        #expect(FreeCatalog.rightsNote(year: "1947", currentYear: 2058) == .publicDomain)
        // the reviewer's Beispiele: in der Schweiz frei, in den USA geschuetzt —
        // genau deshalb Fristen statt Urteil.
        #expect(FreeCatalog.rightsNote(year: "1945", currentYear: 2026) == .termsApply(year: "1945"))
        #expect(FreeCatalog.rightsNote(year: "1953", currentYear: 2026) == .termsApply(year: "1953"))
        // Volldatum: fuehrende vier Ziffern zaehlen.
        #expect(FreeCatalog.rightsNote(year: "1945-06-01", currentYear: 2026) == .termsApply(year: "1945"))
        // Kein Jahr, unlesbares Jahr: nichts behaupten, nicht raten.
        #expect(FreeCatalog.rightsNote(year: nil) == .unknown)
        #expect(FreeCatalog.rightsNote(year: "") == .unknown)
        #expect(FreeCatalog.rightsNote(year: "circa") == .unknown)
        #expect(FreeCatalog.rightsNote(year: "45") == .unknown)
    }

    /// 9081fa1: das Detail reichert die erinnerten Metadaten an, statt sie zu
    /// verlieren — Jahr und Genres waren hier je einmal vergessen worden.
    @MainActor
    @Test("Detail keeps year and genres from the remembered item")
    func detailKeepsRememberedMetadata() async throws {
        let doc = ArchivePopularDoc(
            identifier: "detailtest-1", title: ArchiveStringList(["T"]),
            creator: ArchiveStringList(["C"]), downloads: 1,
            runtime: "1:00:00", licenseurl: nil,
            year: ArchiveStringList(["1927"]),
            subject: ArchiveStringList(["Opera"]))
        let provider = FreeCatalogProvider.shared
        let item = try #require(provider.remember(popular: doc))
        #expect(item.media?.metadata?.publishedYear?.value == "1927")
        #expect(item.media?.metadata?.genres == ["Opera"])
        // The detail path itself needs the network for lva:; the shared helper
        // is exercised through the gut: branch, which resolves locally.
        let gut = GutenbergClient.Book(
            id: 9999, title: "G", authors: nil, languages: ["de"],
            formats: ["audio/mpeg": "https://x/a.mp3",
                      "image/jpeg": "https://x/c.jpg"],
            subjects: ["Satire"])
        let gutItem = try #require(provider.remember(gutenberg: gut))
        let detail = try await provider.fetchItemDetail(itemId: gutItem.id)
        #expect(detail.media.metadata?.genres == ["Satire"])
        #expect(detail.media.tracks?.isEmpty == false)
    }

    @Test("Katalog-Metazeile erfindet weder Jahr noch Laufzeit")
    func catalogMetaLine() {
        #expect(FreeCatalog.catalogMetaLine(year: "1927", runtime: "42 min") == "1927 · 42 min")
        // Jahr fuehrt, weil es die einzige Einordnungshilfe ist.
        #expect(FreeCatalog.catalogMetaLine(year: "1927", runtime: nil) == "1927")
        #expect(FreeCatalog.catalogMetaLine(year: nil, runtime: "42 min") == "42 min")
        // Nichts bekannt: reservierte Leerzeile, keine Erfindung.
        #expect(FreeCatalog.catalogMetaLine(year: nil, runtime: nil) == " ")
        #expect(FreeCatalog.catalogMetaLine(year: "  ", runtime: "") == " ")
    }

}
#endif
