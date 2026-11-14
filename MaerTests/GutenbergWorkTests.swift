// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Playing Gutenberg titles from the stock (way B): the RDF of a work
/// names its audio files, the durations are read once per file on opening
/// and remembered with the addresses. Against the REAL bytes of 5884
/// (three files) and 3002 (one song in two qualities), fetched on 28.09.
nonisolated enum GutenbergWitness {
    static func record(_ number: Int) throws -> Data {
        try CorpusFixture.data("pg\(number)", ext: "rdf", subdirectory: "GutenbergDump")
    }

    /// Measured on 28.09. with AVURLAsset against gutenberg.org.
    static let seconds5884 = [3597.1, 3183.6, 12385.8]

    /// Counts every request; the durations come from the table per file name.
    /// Unchecked because one lock guards the counts; the answers, the status
    /// and the fixture are written by the witness between its questions.
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

    /// Unchecked because one lock guards the count.
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

    @Test("The RDF of 5884 names title, author and three audio files; the zip and the texts do not count")
    func theRecordOf5884() throws {
        let record = try #require(GutenbergRDF.parse(try W.record(5884)))
        #expect(record.title == "The Flying Saucers are Real")
        #expect(record.author == "Keyhoe, Donald E. (Donald Edward)")
        #expect(record.audio.map { ($0 as NSString).lastPathComponent } == ["5884-01.mp3", "5884-02.mp3", "5884-03.mp3"])
        #expect(GutenbergRDF.readingFiles(record.audio).count == 3)
    }

    @Test("The quality rule: the same stem in -high, -med, -low is ONE track, the highest")
    func oneRecordingInSeveralSizes() throws {
        let record = try #require(GutenbergRDF.parse(try W.record(3002)))
        #expect(record.audio.count == 2, "the record names sochi-high and sochi-med")
        #expect(GutenbergRDF.readingFiles(record.audio) == ["https://www.gutenberg.org/files/3002/3002-h/mp3/sochi-high.mp3"])
        let base = "https://www.gutenberg.org/files/1/mp3/"
        let table: [([String], [String])] = [
            ([base + "a-low.mp3", base + "a-med.mp3"], [base + "a-med.mp3"]),
            ([base + "a-low.mp3", base + "a.mp3", base + "a-high.mp3"], [base + "a.mp3"]),
            ([base + "a-high.mp3", base + "b-low.mp3"], [base + "a-high.mp3", base + "b-low.mp3"]),
            // Numbers as numbers: part 10 comes after part 2.
            ([base + "1-10.mp3", base + "1-02.mp3", base + "1-01.mp3"], [base + "1-01.mp3", base + "1-02.mp3", base + "1-10.mp3"]),
            // Music examples in a text are not a reading.
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

    @Test("5884: resuming in the middle of file 2 lands in file 2 at the right place")
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

    @Test("A file without a readable duration makes the title not silently wrong but named")
    func anUnreadablePartIsNamed() throws {
        let parts = work5884().parts
        let broken = GutenbergWork(title: "T", author: nil,
                                   parts: [parts[0], .init(url: parts[1].url, seconds: nil), parts[2]])
        #expect(throws: GutenbergWorkError.partUnreadable(part: 2)) { try broken.tracks() }
        #expect(broken.totalSeconds == nil)
        let sentence = try #require(FreeCatalog.failureReason(GutenbergWorkError.partUnreadable(part: 2), online: true))
        #expect(sentence.contains("2"), "the page names the part: \(sentence)")
        // A single file needs no duration to stand.
        let single = GutenbergWork(title: "T", author: nil, parts: [.init(url: parts[0].url, seconds: nil)])
        #expect(try single.tracks().count == 1)
    }
}

/// What counts as a finding when reading a duration and what does not. Each line is
/// the error that `AVURLAsset.load(.duration)` delivered on 28.09. against a local
/// server with fixed answers (domain, code, underlying).
struct GutenbergPartReadingTests {
    private func error(_ domain: String, _ code: Int, beneath: (String, Int)) -> NSError {
        NSError(domain: domain, code: code,
                userInfo: [NSUnderlyingErrorKey: NSError(domain: beneath.0, code: beneath.1)])
    }

    @Test("Only a delivered file without a duration and an absent one (404, 410) are a finding; 403, 429, 5xx and no network remember nothing")
    func onlyAbsenceAndUnreadableContentAreFindings() {
        let url = NSURLErrorDomain, media = "CoreMediaErrorDomain"
        let table: [(String, NSError, GutenbergPartReading.Outcome)] = [
            ("404", error(url, -1100, beneath: (media, -12938)), .unreadable),
            ("410", error(url, -1008, beneath: (media, -12668)), .unreadable),
            ("400", error(url, -1008, beneath: (media, -16845)), .failed),
            ("401", error(url, -1013, beneath: (media, -16840)), .failed),
            ("403", error("AVFoundationErrorDomain", -11849, beneath: (NSOSStatusErrorDomain, -12873)), .failed),
            ("408", error(url, -1008, beneath: (media, -16845)), .failed),
            ("429", error(url, -1008, beneath: (media, -16845)), .failed),
            ("451", error(url, -1008, beneath: (media, -16845)), .failed),
            ("500", error(url, -1008, beneath: (media, -16847)), .failed),
            ("502", error(url, -1008, beneath: (media, -16848)), .failed),
            ("503", error(url, -1008, beneath: (media, -16849)), .failed),
            ("504", error(url, -1008, beneath: (media, -16850)), .failed),
            ("refused", error(url, -1004, beneath: (url, -1004)), .failed),
            ("unknown host", error(url, -1003, beneath: (url, -1003)), .failed),
            ("offline", error(url, -1009, beneath: (url, -1009)), .failed),
        ]
        for (answer, thrown, expected) in table {
            #expect(GutenbergPartReading.outcome(error: thrown) == expected, "answer \(answer)")
        }
        // A delivered body that is no audio (junk, an HTML page) loads with a
        // non-finite length; that is the unreadable file.
        #expect(GutenbergPartReading.outcome(seconds: .nan) == .unreadable)
        #expect(GutenbergPartReading.outcome(seconds: 0) == .unreadable)
        #expect(GutenbergPartReading.outcome(seconds: 3597.1) == .seconds(3597.1))
    }
}

struct GutenbergWorksTests {
    typealias W = GutenbergWitness

    @Test("The first opening fetches the RDF and one duration per file, one after another; the second asks nothing")
    func resolvedOnceAndKept() async throws {
        let defaults = W.defaults()
        let wire = W.wire5884()
        let first = try #require(try await GutenbergWorks(wire: wire.wire, suiteName: defaults).work(number: 5884))
        #expect(first.parts.map(\.seconds) == W.seconds5884)
        #expect(wire.records == 1 && wire.durations == 3)
        // A new start reads the remembered state, without network.
        let again = try await GutenbergWorks(wire: wire.wire, suiteName: defaults).work(number: 5884)
        #expect(again == first)
        #expect(wire.records == 1 && wire.durations == 3, "kept for good: \(wire.records)/\(wire.durations)")
    }

    @Test("Duration not readable is remembered; a failure remembers nothing and asks again next time")
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

    @Test("A work without a recording (404) is a finding: remembered, no title")
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

    @Test("A title from the stock becomes a gut: title, never an archive title, and plays all three files")
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

    @Test("Without an audio file the title is gone, not silently empty")
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

    @Test("With a stock the overview row does not ask gutendex and shows the conversion of localBrowse")
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
/// The rights of a Gutenberg audiobook are in the RDF per work, not
/// as a blanket for the source: 5884 and 3002 say „Copyrighted“.
@MainActor
struct GutenbergRightsTests {
    typealias W = GutenbergWitness

    @Test("The RDF names the rights per work, the title page shows them, the tile shows no capsule")
    func theRecordStatesTheRights() async throws {
        let record = try #require(GutenbergRDF.parse(try W.record(5884)))
        #expect(record.rights?.hasPrefix("Copyrighted") == true)
        #expect(try #require(GutenbergRDF.parse(try W.record(3002))).rights?.hasPrefix("Copyrighted") == true)

        #expect(FreeCatalog.gutenbergRightsLabel("Public domain in the USA.") == String(localized: "Public domain in the USA"))
        #expect(FreeCatalog.gutenbergRightsLabel(record.rights)
                == String(localized: "Copyrighted, freely distributed by Project Gutenberg"))
        #expect(FreeCatalog.gutenbergRightsLabel(nil) == FreeCatalog.unstatedRights)
        #expect(FreeCatalog.gutenbergRightsLabel("  ") == FreeCatalog.unstatedRights)
        #expect(FreeCatalog.gutenbergRightsLabel("Something else") == FreeCatalog.unstatedRights, "never guessed")

        let provider = FreeCatalogProvider.shared
        let doc = ArchivePopularDoc(identifier: "gut:777001", title: ArchiveStringList(["R"]), creator: nil,
                                    downloads: nil, runtime: nil, licenseurl: nil, year: nil, subject: nil)
        let tile = try #require(provider.remember(popular: doc))
        #expect(provider.licence(forItemId: tile.id) == nil, "no capsule on a tile")
        let stand = W.wire5884()
        stand.fixture = 5884
        _ = try await provider.gutenbergDetail(itemId: tile.id, works: GutenbergWorks(wire: stand.wire, suiteName: W.defaults()))
        #expect(provider.licence(forItemId: tile.id) == String(localized: "Copyrighted, freely distributed by Project Gutenberg"),
                "the title page shows what the record says")
    }

    @Test("The Gutenberg page has the browse row, and it answers from the stock", .needsTheSources)
    func theBrowseShelf() async throws {
        var stock = CatalogStock(surface: "gutenberg", takenAt: 1, watermark: nil, entries: (1...5).map {
            CatalogStockEntry(id: "gut:\($0)", title: "W\($0)", creator: nil, subjects: [],
                              downloads: $0, licenseurl: nil, year: nil)
        })
        stock.popularityComplete = true
        let (answer, way) = try await CatalogShelfSource.preview(source: .gutenberg, shelf: CatalogGenreAxis.browseAllKey,
                                                                 languages: [], rows: 12, keptStock: stock)
        #expect(way == .stock, "the browse row asked past the kept stock")
        let items = try #require(CatalogShelfEntries.shelf(answer, source: .gutenberg, collectionsLast: true)).items
        #expect(items.count == 5 && items.allSatisfy { $0.id.hasPrefix("gut:") }, "titles without a genre are reachable")
        let page = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/CatalogSourcePage.swift"), encoding: .utf8))
        let shelves = try #require(functionBody(of: "private var pageShelves: [(key: String, title: String)] {", in: page))
        #expect(shelves.components(separatedBy: .whitespacesAndNewlines).joined().contains("source==.gutenberg"))
    }
}
#endif
