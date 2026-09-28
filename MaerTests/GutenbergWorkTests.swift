// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Gutenberg-Titel aus dem Bestand spielen (Weg B): die RDF eines Werks
/// nennt seine Tondateien, die Dauern werden beim Oeffnen je Datei einmal
/// gelesen und mit den Adressen gemerkt. Gegen die ECHTEN Bytes von 5884
/// (drei Dateien) und 3002 (ein Lied in zwei Qualitaeten), geholt am 28.09.
nonisolated enum GutenbergWitness {
    static func record(_ number: Int) throws -> Data {
        try CorpusFixture.data("pg\(number)", ext: "rdf", subdirectory: "GutenbergDump")
    }

    /// Gemessen am 28.09. mit AVURLAsset an gutenberg.org.
    static let seconds5884 = [3597.1, 3183.6, 12385.8]

    /// Zaehlt jede Anfrage; die Dauern kommen aus der Tabelle je Dateiname.
    nonisolated final class Wire: @unchecked Sendable {
        private let lock = NSLock()
        private var _records = 0
        private var _durations = 0
        var records: Int { lock.withLock { _records } }
        var durations: Int { lock.withLock { _durations } }
        var answers: [String: GutenbergWorks.PartDuration]
        var status: Int? = 200
        /// Answers every number with this record, so a witness keeps a
        /// number of its own in the shared provider.
        var fixture: Int?

        init(answers: [String: GutenbergWorks.PartDuration]) { self.answers = answers }

        var wire: GutenbergWorks.Wire {
            GutenbergWorks.Wire(
                record: { number in
                    self.lock.withLock { self._records += 1 }
                    return (try GutenbergWitness.record(self.fixture ?? number), self.status)
                },
                duration: { url in
                    self.lock.withLock { self._durations += 1 }
                    return self.answers[url.lastPathComponent] ?? .unreadable
                })
        }
    }

    nonisolated final class Asks: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func add() { lock.withLock { value += 1 } }
    }

    static func wire5884() -> Wire {
        Wire(answers: ["5884-01.mp3": .seconds(seconds5884[0]),
                       "5884-02.mp3": .seconds(seconds5884[1]),
                       "5884-03.mp3": .seconds(seconds5884[2])])
    }

    static func defaults() -> String { "gutenberg-works-\(UUID().uuidString)" }
}

struct GutenbergRDFTests {
    typealias W = GutenbergWitness

    @Test("Die RDF von 5884 nennt Titel, Autor und drei Tondateien; das Zip und die Texte zaehlen nicht")
    func theRecordOf5884() throws {
        let record = try #require(GutenbergRDF.parse(try W.record(5884)))
        #expect(record.title == "The Flying Saucers are Real")
        #expect(record.author == "Keyhoe, Donald E. (Donald Edward)")
        #expect(record.audio.map { ($0 as NSString).lastPathComponent } == ["5884-01.mp3", "5884-02.mp3", "5884-03.mp3"])
        #expect(GutenbergRDF.readingFiles(record.audio).count == 3)
    }

    @Test("Die Qualitaets-Regel: gleicher Stamm in -high, -med, -low ist EINE Spur, die hoechste")
    func oneRecordingInSeveralSizes() throws {
        let record = try #require(GutenbergRDF.parse(try W.record(3002)))
        #expect(record.audio.count == 2, "the record names sochi-high and sochi-med")
        #expect(GutenbergRDF.readingFiles(record.audio) == ["https://www.gutenberg.org/files/3002/3002-h/mp3/sochi-high.mp3"])
        let base = "https://www.gutenberg.org/files/1/mp3/"
        let table: [([String], [String])] = [
            ([base + "a-low.mp3", base + "a-med.mp3"], [base + "a-med.mp3"]),
            ([base + "a-low.mp3", base + "a.mp3", base + "a-high.mp3"], [base + "a.mp3"]),
            ([base + "a-high.mp3", base + "b-low.mp3"], [base + "a-high.mp3", base + "b-low.mp3"]),
            // Zahlen als Zahlen: Teil 10 kommt nach Teil 2.
            ([base + "1-10.mp3", base + "1-02.mp3", base + "1-01.mp3"], [base + "1-01.mp3", base + "1-02.mp3", base + "1-10.mp3"]),
            // Notenbeispiele in einem Text sind keine Lesung.
            (["https://www.gutenberg.org/files/9/9-h/audio/ex1.mp3"], []),
        ]
        for (given, expected) in table {
            #expect(GutenbergRDF.readingFiles(given) == expected, "\(given)")
        }
    }
}

struct GutenbergWorkTracksTests {
    typealias W = GutenbergWitness

    private func work5884() -> GutenbergWork {
        GutenbergWork(title: "T", author: nil, parts: zip(["01", "02", "03"], W.seconds5884).map {
            .init(url: "https://www.gutenberg.org/files/5884/mp3/5884-\($0).mp3", seconds: $1)
        })
    }

    @Test("5884: Fortsetzen mitten in Datei 2 landet in Datei 2 an der richtigen Stelle")
    func resumeLandsInThePartItBelongsTo() throws {
        let work = work5884()
        let tracks = try work.tracks()
        let total = try #require(work.totalSeconds)
        #expect(abs(total - 19_166.5) < 0.01)
        let position = 4000.0
        let index = TrackMath.trackIndex(for: position, tracks: tracks, bookDuration: total)
        #expect(index == 1, "the second file")
        let start = TrackMath.trackStart(index: index, tracks: tracks, bookDuration: total)
        #expect(abs((position - start) - 402.9) < 0.01, "402.9 s into file 2")
        #expect(TrackMath.trackIndex(for: 100, tracks: tracks, bookDuration: total) == 0)
        #expect(TrackMath.trackIndex(for: 7000, tracks: tracks, bookDuration: total) == 2)
    }

    @Test("Eine Datei ohne lesbare Dauer macht den Titel nicht still falsch, sondern benannt")
    func anUnreadablePartIsNamed() throws {
        let parts = work5884().parts
        let broken = GutenbergWork(title: "T", author: nil,
                                   parts: [parts[0], .init(url: parts[1].url, seconds: nil), parts[2]])
        #expect(throws: GutenbergWorkError.partUnreadable(part: 2)) { try broken.tracks() }
        #expect(broken.totalSeconds == nil)
        let sentence = try #require(FreeCatalog.failureReason(GutenbergWorkError.partUnreadable(part: 2)))
        #expect(sentence.contains("2"), "the page names the part: \(sentence)")
        // Eine einzige Datei braucht keine Dauer, um zu stehen.
        let single = GutenbergWork(title: "T", author: nil, parts: [.init(url: parts[0].url, seconds: nil)])
        #expect(try single.tracks().count == 1)
    }
}

struct GutenbergWorksTests {
    typealias W = GutenbergWitness

    @Test("Das erste Oeffnen holt die RDF und je Datei eine Dauer, nacheinander; das zweite fragt nichts")
    func resolvedOnceAndKept() async throws {
        let defaults = W.defaults()
        let wire = W.wire5884()
        let first = try #require(try await GutenbergWorks(wire: wire.wire, suiteName: defaults).work(number: 5884))
        #expect(first.parts.map(\.seconds) == W.seconds5884)
        #expect(wire.records == 1 && wire.durations == 3)
        // Ein neuer Start liest den gemerkten Stand, ohne Netz.
        let again = try await GutenbergWorks(wire: wire.wire, suiteName: defaults).work(number: 5884)
        #expect(again == first)
        #expect(wire.records == 1 && wire.durations == 3, "kept for good: \(wire.records)/\(wire.durations)")
    }

    @Test("Dauer nicht lesbar wird gemerkt; ein Fehlschlag merkt nichts und fragt beim naechsten Mal wieder")
    func onlyFindingsAreKept() async throws {
        let defaults = W.defaults()
        let unreadable = W.wire5884()
        unreadable.answers["5884-02.mp3"] = .unreadable
        let kept = try #require(try await GutenbergWorks(wire: unreadable.wire, suiteName: defaults).work(number: 5884))
        #expect(kept.parts[1].seconds == nil)
        _ = try await GutenbergWorks(wire: unreadable.wire, suiteName: defaults).work(number: 5884)
        #expect(unreadable.durations == 3, "the unreadable finding is kept")

        let other = W.defaults()
        let offline = W.wire5884()
        offline.answers["5884-02.mp3"] = .failed
        await #expect(throws: (any Error).self) {
            _ = try await GutenbergWorks(wire: offline.wire, suiteName: other).work(number: 5884)
        }
        offline.answers["5884-02.mp3"] = .seconds(W.seconds5884[1])
        let healed = try await GutenbergWorks(wire: offline.wire, suiteName: other).work(number: 5884)
        #expect(healed?.parts.map(\.seconds) == W.seconds5884.map { Optional($0) })
        #expect(offline.records == 2, "the failure stored nothing, so the next open asked again")
    }

    @Test("Ein Werk ohne Aufzeichnung (404) ist ein Befund: gemerkt, kein Titel")
    func anAbsentRecordIsKept() async throws {
        let defaults = W.defaults()
        let wire = W.wire5884()
        wire.status = 404
        #expect(try await GutenbergWorks(wire: wire.wire, suiteName: defaults).work(number: 5884) == nil)
        #expect(try await GutenbergWorks(wire: wire.wire, suiteName: defaults).work(number: 5884) == nil)
        #expect(wire.records == 1 && wire.durations == 0)
    }
}

@MainActor
struct GutenbergStockTitleTests {
    typealias W = GutenbergWitness

    private func stockDoc(_ number: Int, title: String = "The Flying Saucers are Real") -> ArchivePopularDoc {
        ArchivePopularDoc(identifier: "gut:\(number)", title: ArchiveStringList([title]),
                          creator: ArchiveStringList(["Keyhoe, Donald E."]), downloads: nil, runtime: nil,
                          licenseurl: nil, year: nil, subject: ArchiveStringList(["Unidentified flying objects"]))
    }

    @Test("Ein Titel aus dem Bestand wird ein gut:-Titel, nie ein archive-Titel, und spielt alle drei Dateien")
    func aStockTitlePlays() async throws {
        let provider = FreeCatalogProvider.shared
        let item = try #require(provider.remember(popular: stockDoc(5884)))
        #expect(item.id == "gut:5884")
        #expect(!item.id.hasPrefix(FreeCatalog.archivePrefix), "never lva:gut:")
        #expect(FreeCatalog.archiveIdentifier(of: item.id) == nil)
        #expect(provider.coverURL(forItemId: item.id)?.absoluteString
                == "https://www.gutenberg.org/cache/epub/5884/pg5884.cover.medium.jpg")

        let wire = W.wire5884()
        let works = GutenbergWorks(wire: wire.wire, suiteName: W.defaults())
        let detail = try await provider.gutenbergDetail(itemId: item.id, works: works)
        let tracks = try #require(detail.media.tracks)
        #expect(tracks.map { ($0.contentUrl as NSString).lastPathComponent } == ["5884-01.mp3", "5884-02.mp3", "5884-03.mp3"])
        #expect(tracks.map(\.startOffset) == [0, W.seconds5884[0], W.seconds5884[0] + W.seconds5884[1]])
        #expect(abs((detail.media.duration ?? 0) - 19_166.5) < 0.01, "progress is right from the first open")
        #expect(detail.media.metadata?.title == "The Flying Saucers are Real")
    }

    @Test("Ohne Tondatei ist der Titel weg, nicht still leer")
    func aWorkWithoutSoundIsGone() async throws {
        let wire = W.wire5884()
        wire.status = 404
        let works = GutenbergWorks(wire: wire.wire, suiteName: W.defaults())
        do {
            _ = try await FreeCatalogProvider.shared.gutenbergDetail(itemId: "gut:5884", works: works)
            Issue.record("a work without sound answered a detail")
        } catch {
            #expect(FreeCatalog.isGone(error))
        }
    }

    @Test("Mit Bestand fragt die Uebersichtsreihe gutendex nicht und zeigt die Umwandlung von localBrowse")
    func theOverviewRowTakesTheStock() async throws {
        let asks = W.Asks()
        var clients = CatalogLoaderWitness.failing()
        clients.gutenberg = GutenbergSeam(audiobooks: { _, _ in asks.add(); return [] })
        let gates = CatalogGates(librivox: false, archiveBooks: false, gutenberg: true, jamendo: false,
                                 freeAudiobooksArea: true, freeClassical: false, netlabels: false, languages: [])
        var stock = CatalogStock(surface: "gutenberg", takenAt: 1, watermark: nil, entries: (1...30).map {
            CatalogStockEntry(id: "gut:\($0)", title: "Work \($0)", creator: nil, subjects: [],
                              downloads: $0, licenseurl: nil, year: nil)
        })
        stock.popularityComplete = true

        let rows = await CatalogSourceLoader.load(using: clients, gates: gates, keptStock: { $0 == .gutenberg ? stock : nil })
        #expect(asks.count == 0, "gutendex was asked \(asks.count) times with a stock in hand")
        #expect(rows.failures[.gutenberg] == nil)
        let browse = try #require(CatalogShelfSource.localBrowse(rows: RowPreview.limit, stock: stock, source: .gutenberg))
        let expected = try #require(CatalogShelfEntries.shelf(browse, source: .gutenberg, collectionsLast: true)).items.map(\.id)
        #expect(!expected.isEmpty && rows.gutenberg.map(\.id) == expected, "one conversion, the same order")
        #expect(rows.gutenberg.allSatisfy { $0.id.hasPrefix(FreeCatalog.gutenbergPrefix) })

        let without = await CatalogSourceLoader.load(using: clients, gates: gates, keptStock: { _ in nil })
        #expect(asks.count > 0, "without a stock the row asks gutendex as before")
        #expect(without.gutenberg.isEmpty)
    }
}
#endif
