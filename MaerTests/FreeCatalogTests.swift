// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// Pure free-catalog mappers. Language filter, duration parsing,
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
        // `de` with ZERO German hits (LibriVox ships few new German books)
        // must fall back to unfiltered. The row shows English instead of
        // vanishing.
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
        // NUMBERS are a tolerated wire form now. Archive.org
        // delivers `year` as int, and the throw on it killed every archive
        // row at once. The old expectation here pinned exactly that bug.
        let numeric = Data("""
        {"response":{"docs":[{"identifier":"x","creator":42}]}}
        """.utf8)
        #expect((try? ArchiveOrgClient.decodePopular(numeric))?.first?.creator?.first == "42")
        // Genuinely foreign types (bool/object) still throw. Wire discipline.
        let broken = Data("""
        {"response":{"docs":[{"identifier":"x","creator":{"a":1}}]}}
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
        // Real georgeblood names: spaces, brackets, hyphens. Hard-encoded,
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

    /// Der alte Fall hielt die Drei-Ebenen-Hierarchie fest, die der Neubau
    /// abschafft. Er ist GEWANDERT, nicht geloescht: die neue Aussage ist,
    /// dass es genau ZWEI Fragen gibt und keine dritte, uebersteuernde
    /// Ebene mehr existiert — kein Schalter darf „an" zeigen und
    /// wirkungslos sein.
    @Test("zwei Fragen, keine dritte Ebene: Quelle erlaubt und Reihe sichtbar")
    func activation() throws {
        let suite = "aktivierung-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let quelle = ExternalSources.internetArchive
        let reihe = try #require(AppRows.row(key: "music.netlabels"))

        // Beide Vorgaben: an. Und jede Frage haengt NUR an ihrem Schalter.
        #expect(ExternalSources.isAllowed(quelle, defaults: defaults))
        #expect(AppRows.isVisible(reihe, defaults: defaults))
        defaults.set(false, forKey: quelle.storageKey)
        #expect(!ExternalSources.isAllowed(quelle, defaults: defaults))
        #expect(AppRows.isVisible(reihe, defaults: defaults),
                "die Quellen-Frage hat die Reihen-Frage uebersteuert")
        defaults.set(true, forKey: quelle.storageKey)
        defaults.set(false, forKey: try #require(reihe.storageKey))
        #expect(!AppRows.isVisible(reihe, defaults: defaults))
        #expect(ExternalSources.isAllowed(quelle, defaults: defaults),
                "die Reihen-Frage hat die Quellen-Frage uebersteuert")
    }

    @Test("die Luecke zwischen den zwei Fragen wird benannt: Reihe an, alle Quellen aus")
    func unsourcedRowIsNamed() throws {
        let reihe = try #require(AppRows.row(key: "music.jamendo"))
        // Every source off: the row stands unsourced and the titles come back.
        #expect(AppRows.unsourcedTitles(reihe, isAllowed: { _ in false }) == ["Jamendo"])
        // Any feeding source left: no line, fewer tiles are the answer.
        #expect(AppRows.unsourcedTitles(reihe, isAllowed: { _ in true }) == nil)
        let mehrquellig = try #require(AppRows.row(key: "home.discoverMusic"))
        #expect(AppRows.unsourcedTitles(mehrquellig, isAllowed: { $0 == "internetArchive" }) == nil,
                "eine verbliebene Quelle traegt die Reihe weiter")
        // A row without foreign sources can never stand unsourced.
        let eigen = try #require(AppRows.row(key: "home.continue"))
        #expect(AppRows.unsourcedTitles(eigen, isAllowed: { _ in false }) == nil)
    }

    /// Der EINE Schreibweg fuehrt die Regel wirklich aus: Reihe
    /// verstecken schaltet die dadurch ungenutzte Quelle ab und NENNT sie;
    /// Reihe zeigen schaltet nie etwas an (die Gegenrichtung ist verboten).
    @Test("setVisible fuehrt die Aufraeum-Regel aus und nennt das Ergebnis")
    func hidingARowRunsTheCleanupRule() throws {
        let suite = "aufraeumen-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        // Jamendo speist genau zwei Reihen. Die erste verstecken: Quelle
        // bleibt (die zweite ist sichtbar). Die zweite auch: Quelle faellt,
        // benannt.
        let reihen = AppRows.rows(feeding: "jamendo").filter(\.toggleable)
        try #require(reihen.count == 2)
        #expect(AppRows.setVisible(reihen[0], false, defaults: defaults).isEmpty)
        #expect(ExternalSources.isAllowed(ExternalSources.jamendo, defaults: defaults))
        let gefallen = AppRows.setVisible(reihen[1], false, defaults: defaults)
        #expect(gefallen == ["jamendo"])
        #expect(!ExternalSources.isAllowed(ExternalSources.jamendo, defaults: defaults))

        // Gegenrichtung: Reihe wieder zeigen schaltet die Quelle NICHT an.
        #expect(AppRows.setVisible(reihen[0], true, defaults: defaults).isEmpty)
        #expect(!ExternalSources.isAllowed(ExternalSources.jamendo, defaults: defaults),
                "Reihe zeigen hat die Quellen-Wahl ueberschrieben")

        // Die Such-Kante haelt die Buch-Quellen am Leben: alle Buch-Reihen
        // versteckt, und librivox bleibt erlaubt, weil die Suche (fester
        // Eintrag) weiter fragt.
        for reihe in AppRows.rows(feeding: "librivox").filter(\.toggleable) {
            _ = AppRows.setVisible(reihe, false, defaults: defaults)
        }
        #expect(ExternalSources.isAllowed(ExternalSources.librivox, defaults: defaults),
                "die Aufraeum-Regel ignoriert die Nicht-Reihen-Nachfrager (Suche)")

        // Radio genauso: die Katalog-Reihe verstecken ist eine
        // Darstellungs-Frage. Der Radio-Scope der Suche (fester Eintrag)
        // haelt radio-browser am Leben; sonst haette ein Reihen-Schalter
        // zwei Spruenge weiter die Zuletzt-gehoert-Anzeige gekostet.
        if let katalog = AppRows.row(key: "radio.catalog") {
            _ = AppRows.setVisible(katalog, false, defaults: defaults)
        }
        #expect(ExternalSources.isAllowed(ExternalSources.radioBrowser, defaults: defaults),
                "die Katalog-Reihe hat die Radio-Quelle mit abgeraeumt")
    }

    /// Die EINE automatische Regel: eine Quelle, die keine sichtbare Reihe
    /// mehr braucht, geht mit aus. NUR diese Richtung.
    @Test("eine Quelle ohne sichtbare Reihe wird als ungenutzt gemeldet")
    func unusedSourcesAreNamed() {
        // Alles sichtbar: nichts ungenutzt.
        #expect(AppRows.sourcesLeftUnused { _ in true }.isEmpty)
        // Nichts sichtbar: jede Quelle mit Reihen-Kante ist ungenutzt —
        // aber eine Quelle OHNE Reihen (Anreicherung wie LRCLIB) wird nie
        // gemeldet, denn sie haengt an keiner Reihe.
        let alle = AppRows.sourcesLeftUnused { _ in false }
        #expect(alle.contains("jamendo"))
        #expect(!alle.contains("lrclib"),
                "eine Quelle ohne Reihen-Kante wird faelschlich abgeraeumt")
        // Nur die Jamendo-Reihen versteckt: genau Jamendo faellt.
        let ohneJamendo = AppRows.sourcesLeftUnused { row in
            !row.sourceKeys.contains("jamendo")
        }
        #expect(ohneJamendo == ["jamendo"])
    }

    @Test("31974ef: importer state — failed stays at ITS book, cancel is neutral, busy refuses")
    @MainActor
    func importerState() async throws {
        let importer = LibriVoxImporter.shared
        importer.cancel()   // clean slate
        #expect(!importer.busy)
        // A book without downloadable sections fails WITHOUT network. The
        // terminal state keeps the book id (foreign sheets gate on it).
        let empty = LibriVoxBook(id: "42", title: "T", language: nil,
                                 totaltimesecs: nil, url_iarchive: nil,
                                 url_librivox: nil, url_rss: nil,
                                 authors: nil, sections: [], genres: nil)
        importer.start(book: empty, itemId: "lv:42", libraryId: "L", folderId: "F")
        // The run task is async. Poll briefly for the terminal phase.
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

    /// Die Genre-Achse war TOTES HOLZ: die API
    /// liefert Genres, aber LibriVoxBook decodierte sie nicht, der Provider
    /// setzte an sieben Stellen nil, die Filterleiste renderte nie. Ein Feld,
    /// das ueberall nil gesetzt wird, faellt beim naechsten Umbau wieder raus,
    /// ohne dass etwas rot wird. Dieser Test weist am ECHTEN Korpus nach,
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
        // The epoch entry stays in. The axis filters it, not the transport.
        #expect(genres.allSatisfy { !$0.isEmpty })
    }

    /// archive.org liefert
    /// `year` als ZAHL; die String-only-Toleranz warf typeMismatch und
    /// killte ALLE archive-Reihen zugleich. Live-Fixture, nicht gebastelt.
    @Test("Numeric year decodes (the type that killed every archive row)")
    func numericYearDecodes() throws {
        let data = try CorpusFixture.data("archive-year-numeric", ext: "json", subdirectory: "WireCorpus")
        let docs = try ArchiveOrgClient.decodePopular(data)
        #expect(!docs.isEmpty)
        // Mindestens ein Jahr kommt als String-Wert durch.
        #expect(docs.contains { !($0.year?.values.isEmpty ?? true) })
        // Und die Fristen-Staffel kann damit rechnen.
        if let year = docs.compactMap({ $0.year?.first }).first {
            #expect(Int(year.prefix(4)) != nil)
        }
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

/// The free-audiobook row's SELECTION (per-language
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
        // finding if the fetch itself failed).
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
        // Middle ground: 5 % of 6 GB ≈ 307 MB. Used as is.
        let sixGB = 6 * 1024 * mb
        #expect(ImageCache.cacheCapBytes(freeBytes: sixGB) == Int64(Double(sixGB) * 0.05))
        // Nearly full device: the floor keeps the cache usable.
        #expect(ImageCache.cacheCapBytes(freeBytes: 500 * mb) == 150 * mb)
        #expect(ImageCache.cacheCapBytes(freeBytes: 0) == 150 * mb)
        // Nonsense input cannot produce a negative cap.
        #expect(ImageCache.cacheCapBytes(freeBytes: -1) == 150 * mb)
        // The old fixed value sits between floor and ceiling. The change is
        // an ADJUSTMENT, not a new regime.
        #expect(ImageCache.cacheCapBytes(freeBytes: 40 * 1024 * mb) > 200 * mb)
    }

    @Test("the junk meta item stays filtered (Librivox M4b collection)")
    func junkStaysFiltered() {
        #expect(FreeCatalog.isArtifactDoc(identifier: "librivox_m4b_collection",
                                          title: "Librivox M4b Collection Audiobooks Main"))
    }
}

/// The feed's CHANNEL artwork. Read from the head, never from an
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

/// Container feeds in work order. Pure recognition, contiguous
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

/// The two catalog pages' genre axes. Chip → chart ids (derived
/// from what the charts CONTAIN) and LibriVox genres → browsable shelves.
struct CatalogGenreAxisTests {
    @Test("radio-play chips map to the measured charts; True Crime stays out")
    func hoerspielChips() {
        let byKey = Dictionary(uniqueKeysWithValues:
            CatalogGenreAxis.hoerspielChips.map { ($0.key, $0.genreIds) })
        // Krimi rides DRAMA: that chart is headed by ARD Radio Tatort and
        // Kriminalhörspiel. True Crime (1488) is documentary. Including it
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

    /// Der LibriVox-Gattungsweg ist gefallen (zwei Kennungen fuer
    /// dieselben Titel waeren zwei Wahrheiten). Das VERHALTEN lebt auf der
    /// EINEN Subject-Achse weiter, und die deckt beide Schreibfamilien. Der
    /// Fall wandert deshalb mit, statt mit der Funktion zu verschwinden.
    @Test("Gattungen falten auf Faecher; EPOCHEN werden nie eines")
    func genresFoldOntoShelves() {
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Literary Fiction"]) == ["fiction"])
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Detective Fiction"]) == ["crime"])
        // The measured mix: genre AND epoch in one field. The epoch drops,
        // so no year ends up between the shelves.
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Published 1800-1900"]).isEmpty)
        #expect(CatalogGenreAxis.shelves(
            forSubjects: ["Published 1800-1900", "Science Fiction"]) == ["scifi"])
        #expect(CatalogGenreAxis.isEpoch("Published 1800-1900"))
        #expect(!CatalogGenreAxis.isEpoch("Science Fiction"))
        // Unknown stays unknown. No guessing.
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Völlig Unbekannt"]).isEmpty)
        #expect(CatalogGenreAxis.shelves(forSubjects: []).isEmpty)
        // Several genres → several shelves, deduped and in BROWSE order
        // (not in the order the source happened to list them).
        let many = CatalogGenreAxis.shelves(
            forSubjects: ["Poetry", "Detective Fiction", "Literary Fiction", "Poetry"])
        #expect(many == ["fiction", "crime", "poetry"])
        // Case and whitespace tolerance (sources are inconsistent).
        #expect(CatalogGenreAxis.shelves(forSubjects: ["  SCIENCE FICTION "]) == ["scifi"])
    }

    @Test("e948444: licence labels stay honest — no blanket 'public domain'")
    func licenceLabels() {
        #expect(FreeCatalog.licenceLabel("http://creativecommons.org/licenses/by-nc-nd/2.5/")
                == "CC BY-NC-ND")
        #expect(FreeCatalog.licenceLabel("http://creativecommons.org/licenses/by-nc-sa/3.0/us/")
                == "CC BY-NC-SA")
        // P6a: an uploader's PD DECLARATION names its source. The plain
        // "Public domain" stays reserved for our term-based derivation.
        #expect(FreeCatalog.licenceLabel("http://creativecommons.org/licenses/publicdomain/")
                == String(localized: "Public domain (per source)"))
        // Eine Form, die wir nicht LESEN koennen, wird nicht roh gezeigt:
        // die Kapsel trug am Geraet "https://truyendo…" als Rechte-Angabe.
        // Sie sagt jetzt dasselbe wie eine fehlende Angabe, denn fuer den
        // Leser ist es dasselbe. Weder eine URL noch "frei".
        #expect(FreeCatalog.licenceLabel("https://example.org/some-licence")
                == FreeCatalog.unstatedRights)
        // Und der Autoren-Zwilling derselben Klasse: eine URL ist kein Name.
        #expect(FreeCatalog.displayableAuthor("http://sites.google.com/x") == nil)
        #expect(FreeCatalog.displayableAuthor("www.truyendocviet.com") == nil)
        #expect(FreeCatalog.displayableAuthor("  Jules Verne ") == "Jules Verne")
        #expect(FreeCatalog.displayableAuthor("") == nil)
        // Eine fehlende Angabe schweigt NICHT mehr. Sie ist selbst eine
        // Information. Und ausdruecklich keine Behauptung ueber die Rechte.
        #expect(FreeCatalog.licenceLabel(nil) == FreeCatalog.unstatedRights)
        #expect(FreeCatalog.licenceLabel("") == FreeCatalog.unstatedRights)
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

    /// Absender-Regel UND Form-Kategorie. Die Fälle unten sind
    /// Echte Messwerte. Links vier Sendungen, die alle `Drama`/`Fiction`
    /// tragen, rechts vier Absender-Treffer derselben Regel, die KEINE
    /// Hörspiele sind. Ohne das Form-Gatter stünde eine Sport-Sendung in der
    /// Hörspiel-Reihe.
    @Test("the form gate keeps the broadcaster's news out of the radio-play row")
    func oerrFormGate() {
        // Echte Hörspiel-Sendungen (gemessen, gb-Storefront):
        for real in [["Drama", "Podcasts", "Fiction"], ["Fiction"], ["Drama"]] {
            #expect(OERRCuration.isFiction(categories: real))
        }
        // Echte Fehltreffer der Absender-Regel (gemessen, au/ca/nz):
        for wrong in [["Sport", "Podcasts"],                  // ABC AFL Daily
                      ["News", "Podcasts"],                   // Checkpoint, Front Burner
                      ["Society & Culture", "Podcasts"],      // Q with Tom Power
                      ["Religion & Spirituality", "Podcasts"],// Soul Search
                      ["Kids & Family", "Podcasts"],          // It Takes A Village
                      ["Podcasts"]] {                         // Best of ABC Sport Podcast
            #expect(!OERRCuration.isFiction(categories: wrong))
        }
        // Keine Kategorien ⇒ Form UNBEKANNT ⇒ nicht aufnehmen (dieselbe
        // Linie wie bei unbekannter Rechtelage).
        #expect(!OERRCuration.isFiction(categories: nil))
        #expect(!OERRCuration.isFiction(categories: []))
    }

    @Test("L2: broadcasters carry their own search terms, others keep the language term")
    func oerrBroadcasterSearchTerms() {
        let all = OERRCuration.broadcasters
        let abc = all.first { $0.country == .australia }
        #expect(!(abc?.searchTerms.isEmpty ?? true),
                "au/ca/nz need own terms - the language term drama finds only the BBC there")
        // German broadcasters are found by the language term and must NOT
        // have been touched by L2.
        let de = all.filter { $0.language == "de" }
        #expect(!de.isEmpty)
        #expect(de.allSatisfy { $0.searchTerms.isEmpty })
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
    // MARK: - Abbruch ist kein Fehler

    /// `try?` unter `async let` frass die Unterscheidung. Eine
    /// stornierte .task wurde als vier kaputte Quellen verbucht. Die pure
    /// Klassifikation ist der Zaun: Abbruch ⇒ nil (kein failure-Eintrag),
    /// alles andere ⇒ kurzer Grund fuer Log UND Fehlerzeile.
    @Test("Cancellation classifies as nil; real failures carry a tellable reason")
    func failureClassification() {
        #expect(FreeCatalog.failureReason(CancellationError()) == nil)
        #expect(FreeCatalog.failureReason(URLError(.cancelled)) == nil)
        // EIN Blick unterscheidet 429 / HTML-Antwort / Transport.
        #expect(FreeCatalog.failureReason(APIError.http(429, "slow down")) == "HTTP 429")
        #expect(FreeCatalog.failureReason(URLError(.timedOut)) == "URLError \(URLError.Code.timedOut.rawValue)")
        let decode = FreeCatalog.CatalogDecodeError(status: 200, answerPrefix: "<html><head>challenge")
        #expect(FreeCatalog.failureReason(decode) == "decode (HTTP 200): <html><head>challenge")
        #expect(FreeCatalog.failureReason(FreeCatalog.CatalogDecodeError(status: nil, answerPrefix: "x"))
                == "decode (HTTP ?): x")
    }

    // MARK: - EINE Achse fuer zwei Schreibfamilien

    /// Gutenbergs LCSH-subjects landen auf DENSELBEN Regalen wie die
    /// LibriVox-Genres. Erweitert, nicht daneben gebaut. Die Faelle stammen
    /// aus Messung der 1.124 Audio-Titel.
    @Test("LCSH subjects map onto the shared shelves")
    func lcshShelves() {
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Domestic fiction"]) == ["fiction"])
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Adventure stories"]) == ["adventure"])
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Bildungsromans"]) == ["fiction"])
        // Vier standen woertlich schon in librivoxAxis. Dieselbe Achse traegt.
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

    // MARK: - Spiegel-Diff + OPML-Kette

    /// Der Server ist Quelle der Wahrheit. Gespiegelt, nicht
    /// importiert. Der Diff ist die Stelle, an der ein stiller Fehler Abos
    /// fressen wuerde; deshalb pur und am Fixture getestet.
    @Test("Pinchflat mirror diff: new in, orphaned out, hidden stays out")
    func pinchflatMirrorDiff() {
        let server = ["https://s/a.xml", "https://s/b.xml", "https://s/c.xml"]
        // b ist schon da, d ist verwaist, c ist ausgeblendet.
        let diff = PinchflatMirror.diff(
            serverFeeds: server,
            mirrored: ["https://s/b.xml", "https://s/d.xml"],
            hidden: ["https://s/c.xml"])
        #expect(diff.toSubscribe == ["https://s/a.xml"])
        #expect(diff.toUnsubscribe == ["https://s/d.xml"])
        // Ein ausgeblendeter Kanal wird NIE re-abonniert. Auch wenn der
        // Server ihn weiter listet (die Opt-out-Ausnahme der Nachschaerfung).
        let again = PinchflatMirror.diff(serverFeeds: server,
                                         mirrored: ["https://s/a.xml", "https://s/b.xml"],
                                         hidden: ["https://s/c.xml"])
        #expect(again.toSubscribe.isEmpty)
        #expect(again.toUnsubscribe.isEmpty)
        // Leerer Server ⇒ alles verwaist (Fortschritt bleibt, Regel wie beim
        // Abbestellen). Aber NUR die Gruppe, hidden unberuehrt.
        let empty = PinchflatMirror.diff(serverFeeds: [], mirrored: ["https://s/a.xml"], hidden: [])
        #expect(empty.toUnsubscribe == ["https://s/a.xml"])
    }

    /// Die eingefrorene echte OPML-Antwort laeuft durch DENSELBEN Parser wie
    /// der Import. Die Kette Server → Feed-URLs ist der Zaun.
    @Test("Pinchflat OPML fixture parses via the shared parser")
    func pinchflatOPMLParses() throws {
        let data = try CorpusFixture.data("pinchflat-sources", ext: "opml", subdirectory: "WireCorpus")
        let urls = try #require(PodcastImport.parseOPML(data))
        #expect(urls.count == 2)
        #expect(urls.allSatisfy { $0.contains("/sources/") && $0.hasSuffix("/feed.xml") })
        // Verifiziert am Pruefstand: die xmlUrls kommen OHNE route_token.
        #expect(urls.allSatisfy { !$0.contains("route_token") })
    }

    // MARK: - Quellen-Aufteilung

    /// The condition "no tile appears in both tabs" holds
    /// STRUKTURELL: feed- und katalogbasierte Quellen sind disjunkte Mengen
    /// EINES enums, und die Kuration verteilt jeden Feed auf genau eine Reihe.
    @Test("Catalog sources split disjointly; every curated feed lands exactly once")
    @MainActor
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

        // Ohne en bleibt OERR uebrig. Die anderen Reihen sind leer, nicht kaputt.
        #expect(!CatalogSource.oerr.curatedFeeds(forLanguages: ["de"]).isEmpty)
        // X²·2: the fused row keeps its GERMAN entries without en active.
        // The community additions, not the English stock.
        let deOnly = CatalogSource.independents.curatedFeeds(forLanguages: ["de"])
        #expect(!deOnly.isEmpty)
        #expect(deOnly.allSatisfy { $0.language == nil })
        // Katalog-Quellen liefern nie Feeds.
        #expect(CatalogSource.librivox.curatedFeeds(forLanguages: codes).isEmpty)
    }

    // MARK: - Der Zaun gegen den Namensraum-Fehler

    /// A namespace bug locked the user out of their own server:
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

    /// Der vorige Zaun prueft die REGEL. Dieser prueft den WEG.
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

    // MARK: - Rechtelage wird nicht geraten

    /// Die Metazeile zeigt NUR, was die Quelle liefert. Fehlt das Jahr, steht
    /// dort keins. Georgeblood traegt bei etwa zwei Dritteln der Titel keins,
    /// und ein geratenes Jahr waere bei einer Sammlung ohne Lizenzfeld die
    /// zweite Falschaussage nach der Kapsel.
    /// Schutzfristen sind ortsabhaengig. Schweiz 50, EU 70, USA 100
    /// Jahre fuer Tonaufnahmen. Deshalb darf gemeinfrei nur stehen, wo auch
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
        // Die Grenze ALTERT MIT. Am 1.1.2027 wird 1926 frei. Die
        // alte Konstante waere fuer immer ein Jahr zu scheu geblieben.
        #expect(FreeCatalog.rightsNote(year: "1926", currentYear: 2027) == .publicDomain)
        // 1947er springen NICHT nach 100 Jahren (110er-Band des MMA) …
        #expect(FreeCatalog.rightsNote(year: "1947", currentYear: 2048) == .termsApply(year: "1947"))
        // … sondern erst 2058.
        #expect(FreeCatalog.rightsNote(year: "1947", currentYear: 2058) == .publicDomain)
        // 1957–1972 warten auf den 2067-Sunset …
        #expect(FreeCatalog.rightsNote(year: "1970", currentYear: 2067) == .termsApply(year: "1970"))
        #expect(FreeCatalog.rightsNote(year: "1970", currentYear: 2068) == .publicDomain)
        // … aber NACH 1972 gilt regulaeres Copyright. 1980 ist 2068 NICHT
        // frei (der alte default haette es behauptet), sondern erst 2076.
        #expect(FreeCatalog.rightsNote(year: "1980", currentYear: 2068) == .termsApply(year: "1980"))
        #expect(FreeCatalog.rightsNote(year: "1980", currentYear: 2076) == .publicDomain)
        // Beispiele: in der Schweiz frei, in den USA geschuetzt.
        // Genau deshalb Fristen statt Urteil.
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

    /// Das Detail reichert die erinnerten Metadaten an, statt sie zu
    /// verlieren. Jahr und Genres waren hier je einmal vergessen worden.
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

    @Test("Katalog-Mischreihe: fair verschraenkt, gedeckelt, keine leeren Spuren")
    func catalogMixRow() {
        func feed(_ n: Int) -> HoerspielCuration.Entry {
            .init(title: "F\(n)", author: "A", feedURL: "https://f/\(n)")
        }
        func item(_ id: String) -> LibraryItem {
            LibraryItem(id: id, media: nil, addedAt: nil)
        }
        // The row is seeded now. With single-element lanes the
        // shuffle has nothing to move, so the fair interleave stays exactly
        // observable; multi-element lane ORDER is covered by the mix tests.
        let tiles = CatalogMix.row(feedGroups: [[feed(1)]],
                                   itemGroups: [[item("a")]], limit: 10,
                                   seed: 7, previous: [])
        #expect(tiles.map(\.id) == ["feed:https://f/1", "item:a"])
        // Cap applies across the mix.
        let capped = CatalogMix.row(feedGroups: [[feed(1), feed(2), feed(3)]],
                                    itemGroups: [[item("a"), item("b"), item("c")]],
                                    limit: 3, seed: 7, previous: [])
        #expect(capped.count == 3)
        // An empty lane never starves the merge (filtered before the merge).
        let sparse = CatalogMix.row(feedGroups: [[]],
                                    itemGroups: [[item("a")], [], [item("b")]],
                                    limit: 10, seed: 7, previous: [])
        #expect(Set(sparse.map(\.id)) == ["item:a", "item:b"])
        // All empty: empty row (the section hides on the surface).
        #expect(CatalogMix.row(feedGroups: [], itemGroups: [[]], limit: 5,
                               seed: 7, previous: []).isEmpty)

        // The mixing rules, each as its own claim:
        let lane = (1...8).map { CatalogMix.Tile.feed(feed($0)) }
        // Same seed ⇒ same row: nothing re-sorts within a session.
        #expect(CatalogMix.shuffle(lane, seed: 42, previous: []).map(\.id)
                == CatalogMix.shuffle(lane, seed: 42, previous: []).map(\.id))
        // A different seed moves things (eight elements. A collision of all
        // positions is astronomically unlikely, and the claim is "not static").
        #expect(CatalogMix.shuffle(lane, seed: 1, previous: []).map(\.id)
                != CatalogMix.shuffle(lane, seed: 2, previous: []).map(\.id))
        // The malus: last round's tiles sort BEHIND everything fresh, so the
        // shuffle cannot deal the same trio again.
        let previous: Set<String> = ["feed:https://f/1", "feed:https://f/2", "feed:https://f/3"]
        let mixed = CatalogMix.shuffle(lane, seed: 9, previous: previous)
        let freshCount = lane.count - previous.count
        #expect(Set(mixed.prefix(freshCount).map(\.id)).isDisjoint(with: previous),
                "die letzte Runde muss hinter allem Frischen stehen")
        // Nothing is LOST to the malus. It re-orders, it never drops.
        #expect(Set(mixed.map(\.id)) == Set(lane.map(\.id)))
    }

    @Test("Auftrag O: Track-Titel aus dem Dateinamen, Position -> Folgen-Index")
    func archiveSeriesHelpers() {
        // File name is the episode title: percent-decoded, extension dropped,
        // underscores become spaces.
        #expect(FreeCatalog.trackDisplayTitle(
            contentUrl: "https://archive.org/download/x/Ep%2001_The_Thing.mp3")
            == "Ep 01 The Thing")
        #expect(FreeCatalog.trackDisplayTitle(contentUrl: "https://a/b/no-extension")
            == "no-extension")
        // The ONE item position falls into exactly one episode.
        func track(_ i: Int, start: Double, dur: Double) -> ABSAudioTrack {
            ABSAudioTrack(index: i, startOffset: start, duration: dur,
                          contentUrl: "https://x/\(i).mp3", metadata: nil)
        }
        let tracks = [track(0, start: 0, dur: 100), track(1, start: 100, dur: 50)]
        #expect(FreeCatalog.trackIndex(at: 0, tracks: tracks) == nil)     // no position
        #expect(FreeCatalog.trackIndex(at: 42, tracks: tracks) == 0)
        #expect(FreeCatalog.trackIndex(at: 100, tracks: tracks) == 1)
        #expect(FreeCatalog.trackIndex(at: 999, tracks: tracks) == 1)     // past end: last
        #expect(FreeCatalog.trackIndex(at: 42, tracks: []) == nil)
    }

    @Test("P1: Sprach-Rueckfall ist Sitzungszustand — Seite 2 blaettert ungefiltert weiter")
    func archiveFallbackPagesOn() async throws {
        // Page 1: the language-filtered query is empty, the base query has
        // stock. The call reports the fallback.
        func doc(_ id: String) -> ArchivePopularDoc {
            ArchivePopularDoc(identifier: id, title: nil, creator: nil,
                              downloads: nil, runtime: nil, licenseurl: nil,
                              year: nil, subject: nil)
        }
        let page1 = try await ArchiveOrgClient.audiobooksOutsideLibriVox(
            rows: 20, languageCodes: ["de"], page: 1,
            fetch: { query, _, _ in query.contains("language:") ? [] : [doc("a")] })
        #expect(page1.docs.map(\.identifier) == ["a"])
        #expect(page1.unfiltered)
        // Page 2 WITH the session flag: no filtered query fires at all.
        var queries: [String] = []
        let page2 = try await ArchiveOrgClient.audiobooksOutsideLibriVox(
            rows: 20, languageCodes: ["de"], page: 2, unfiltered: true,
            fetch: { query, _, _ in queries.append(query); return [doc("b")] })
        #expect(page2.docs.map(\.identifier) == ["b"])
        #expect(queries.count == 1 && !queries[0].contains("language:"))
        // Filtered mode with stock: deeper empty pages legitimately end.
        let end = try await ArchiveOrgClient.audiobooksOutsideLibriVox(
            rows: 20, languageCodes: ["de"], page: 3,
            fetch: { _, _, _ in [] })
        #expect(end.docs.isEmpty && !end.unfiltered)
    }

    @Test("P4: Sperrliste — die sechs Kennungen fallen, Nachbarn bleiben")
    func curatedExclusions() {
        func doc(_ id: String) -> ArchivePopularDoc {
            ArchivePopularDoc(identifier: id, title: nil, creator: nil,
                              downloads: nil, runtime: nil, licenseurl: nil,
                              year: nil, subject: nil)
        }
        #expect(!FreeCatalog.isCuratedArchiveDoc(doc("HMSUlyssesAM")))
        #expect(!FreeCatalog.isCuratedArchiveDoc(doc("BearislandAM")))
        #expect(FreeCatalog.isCuratedArchiveDoc(doc("art_of_war_full")))
    }

    @Test("P5/P7: neue Regale — IA-Religion, OTR-Western/Suspense/Variete")
    func newShelves() {
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Religion"]) == ["religion"])
        #expect(CatalogGenreAxis.shelves(forSubjects: ["western"]) == ["western"])
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Suspense"]) == ["horror"])
        #expect(CatalogGenreAxis.shelves(forSubjects: ["variety"]) == ["music"])
        // Boilerplate stays unmapped. The axis is conservative.
        #expect(CatalogGenreAxis.shelves(forSubjects: ["old time radio", "otrr set"]).isEmpty)
    }

    @Test("Befund W: Jamendo-Namen dekodieren HTML-Entities an der Einlese-Stelle")
    func jamendoEntitiesDecode() {
        let track = JamendoTrack(id: "w1", name: "Song &quot;Alpha&quot;",
                                 artist_name: "Bessonn&amp;sa", image: nil,
                                 audio: "https://x/a.mp3", shareurl: nil, duration: 60)
        let item = FreeCatalogProvider.shared.remember(track: track)
        #expect(item?.title == "Song \"Alpha\"")
        #expect(item?.author == "Bessonn&sa")
    }

    @Test("P8: Musik-Achse — Faltung aufs Eltern-Regal, Server-Tags je Regal")
    func musicAxisFolding() {
        // Die gefaltete Achse: der Name des Fachs FUEHRT, der Rest folgt
        // alphabetisch und gedeckelt. (Ein rein alphabetischer Schnitt haette
        // `electronic` aus dem Elektronik-Fach geworfen. 8bit bis dance
        // fuellen die ersten acht.)
        #expect(CatalogGenreAxis.musicTags(forShelf: "pop").first == "pop")
        #expect(CatalogGenreAxis.musicTags(forShelf: "pop").contains("electropop"))
        #expect(CatalogGenreAxis.musicTags(forShelf: "folk").contains("singersongwriter"))
        #expect(CatalogGenreAxis.musicTags(forShelf: "hiphop").contains("rap"))
        #expect(CatalogGenreAxis.musicTags(forShelf: "unknown").isEmpty)
        // Every shelf resolves at least its own tag. Und zwar zuerst.
        for shelf in CatalogGenreAxis.musicShelves {
            #expect(CatalogGenreAxis.musicTags(forShelf: shelf.key).first == shelf.key,
                    "\(shelf.key) fuehrt seine eigene Abfrage nicht an")
            #expect(CatalogGenreAxis.musicTags(forShelf: shelf.key).count <= 8)
        }
    }

    @Test("Q2: Titel-Normalisierung — Artikel zurueck, by-Anhang ab, Version als Feld")
    func titleNormalization() {
        let full = FreeCatalog.normalizedTitle("Struwwelpeter, Der by Heinrich Hoffmann (1809 - 1894)")
        #expect(full.title == "Der Struwwelpeter")
        #expect(full.version == nil)
        let versioned = FreeCatalog.normalizedTitle("Art of War, The by Sun Tzu (554 - 496), version 2")
        #expect(versioned.title == "The Art of War")
        #expect(versioned.version == 2)
        let paren = FreeCatalog.normalizedTitle("Faust (version 3)")
        #expect(paren.title == "Faust")
        #expect(paren.version == 3)
        // Conservative: a mid-title "by" without a dated tail survives.
        #expect(FreeCatalog.normalizedTitle("Death by Chocolate").title == "Death by Chocolate")
        // French articles too; plain titles pass through untouched.
        #expect(FreeCatalog.normalizedTitle("Misérables, Les by Victor Hugo (1802 - 1885)").title
                == "Les Misérables")
        #expect(FreeCatalog.normalizedTitle("Dracula").title == "Dracula")
    }

    @Test("Q3: Metazeile traegt die Lesung dezent")
    func metaLineCarriesReading() {
        #expect(FreeCatalog.catalogMetaLine(year: "1927", runtime: "42 min", readingVersion: 2)
                == "1927 · 42 min · " + String(localized: "Reading \(2)"))
        #expect(FreeCatalog.catalogMetaLine(year: nil, runtime: nil, readingVersion: nil) == " ")
    }

    @Test("X²·3: Positivlisten-Regel — Token-genau, keine Substring-Fehlgriffe")
    func oerrRule() {
        // Word-boundary precision: "hr" the broadcaster matches, "Uhr" not.
        #expect(OERRCuration.matches(artistName: "hr")?.country == .germany)
        #expect(OERRCuration.matches(artistName: "Die Uhr GmbH") == nil)
        #expect(OERRCuration.matches(artistName: "WDR")?.country == .germany)
        #expect(OERRCuration.matches(artistName: "Schweizer Radio und Fernsehen (SRF)")?.country == .switzerland)
        #expect(OERRCuration.matches(artistName: "BBC Radio 4")?.country == .uk)
        #expect(OERRCuration.matches(artistName: "Rundfunk Berlin-Brandenburg")?.country == .germany)
        // Not on the list: missing without remark (the whole rule).
        #expect(OERRCuration.matches(artistName: "NPR") == nil)
        #expect(OERRCuration.matches(artistName: nil) == nil)
        // Language gating drives visibility.
        #expect(OERRCuration.active(forLanguages: ["de"]).allSatisfy { $0.language == "de" })
        #expect(OERRCuration.active(forLanguages: []).isEmpty)
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


    // MARK: - Track titles from the source

    private func archiveFile(name: String, title: String? = nil, track: String? = nil,
                             length: String = "180") -> ArchiveFile {
        ArchiveFile(name: name, length: length, title: title, track: track, format: "VBR MP3")
    }

    @Test("the source's own track title wins over the file name")
    func statedTitleWins() {
        let file = archiveFile(name: "01 - dwk123_01_april_showers.mp3", title: "April Showers")
        #expect(FreeCatalog.trackTitle(file) == "April Showers")
        // Without a stated title the file name stays the fallback.
        let bare = archiveFile(name: "gunsmoke_52-04-26.mp3")
        #expect(FreeCatalog.trackTitle(bare) == FreeCatalog.trackDisplayTitle(contentUrl: "gunsmoke_52-04-26.mp3"))
        // A blank title is not a title.
        #expect(FreeCatalog.trackTitle(archiveFile(name: "x.mp3", title: "   ")).isEmpty == false)
    }

    @Test("track numbers order the release, in both spellings")
    func trackNumbersOrderTheRelease() {
        #expect(FreeCatalog.trackNumber(archiveFile(name: "a", track: "7")) == 7)
        #expect(FreeCatalog.trackNumber(archiveFile(name: "a", track: "7/15")) == 7)
        #expect(FreeCatalog.trackNumber(archiveFile(name: "a", track: nil)) == nil)
        // Numbered files sort by number, not by name (10 after 9).
        let nine = FreeCatalog.orderKey(archiveFile(name: "z_nine.mp3", track: "9"))
        let ten = FreeCatalog.orderKey(archiveFile(name: "a_ten.mp3", track: "10"))
        #expect(nine < ten)
        // Without numbers the file name keeps the order it always had.
        let a = FreeCatalog.orderKey(archiveFile(name: "a.mp3"))
        let b = FreeCatalog.orderKey(archiveFile(name: "b.mp3"))
        #expect(a < b)
    }

    @Test("the built tracks carry their title")
    func builtTracksCarryTheirTitle() {
        let files = [archiveFile(name: "02.mp3", title: "Downtown Irony", track: "2"),
                     archiveFile(name: "01.mp3", title: "April Showers", track: "1")]
        let tracks = FreeCatalog.archiveTracks(identifier: "DWK123", files: files)
        #expect(tracks.count == 2)
        #expect(tracks.first?.metadata?.title == "April Showers", "track 1 comes first")
        #expect(tracks.last?.metadata?.title == "Downtown Irony")
    }
}
#endif
