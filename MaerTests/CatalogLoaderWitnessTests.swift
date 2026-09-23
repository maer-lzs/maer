// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Each catalogue loader runs offline with stand-in clients: an answer
/// arrives as items, and a failure arrives with the reason of the error the
/// stand-in threw. The stand-ins are the shared seams, one per client.
nonisolated enum CatalogLoaderWitness {
    struct Asked: Error {}

    /// The error every failing stand-in throws, and the reason it must come
    /// back as.
    static let offline = URLError(.notConnectedToInternet)
    static var offlineReason: String { CatalogLoadOutcome.reason(offline) }

    static func track() -> JamendoTrack {
        JamendoTrack(id: "witness-\(UUID().uuidString)", name: "T", artist_name: "A", image: nil,
                     audio: "https://example.org/a.mp3", shareurl: nil, duration: 60)
    }

    static func doc() -> ArchivePopularDoc {
        ArchivePopularDoc(identifier: "witness-\(UUID().uuidString)", title: ArchiveStringList(["T"]),
                          creator: nil, downloads: 1, runtime: nil, licenseurl: nil,
                          year: nil, subject: nil, collection: ArchiveStringList(["etree"]))
    }

    static func book() -> LibriVoxBook {
        LibriVoxBook(id: "witness-\(UUID().uuidString)", title: "T", language: "English", totaltimesecs: 60,
                     url_iarchive: nil, url_librivox: nil, url_rss: nil, authors: nil, sections: [], genres: nil)
    }

    static func meta() throws -> ArchiveOrgClient.MetadataResponse.Meta {
        try JSONDecoder().decode(ArchiveOrgClient.MetadataResponse.Meta.self,
                                 from: Data(#"{"title":"T","description":"D"}"#.utf8))
    }

    /// Every question answers. Gutenberg answers empty: its book shape is
    /// only built by its decoder, and an empty answer is still no failure.
    static func answering(meta: ArchiveOrgClient.MetadataResponse.Meta? = nil,
                          liveness: DeadCatalogItems.Liveness = .alive) -> CatalogClients {
        CatalogClients(
            archive: ArchiveSeam(
                popularLibriVoxByLanguage: { _, _, _, _ in [doc(), doc()] },
                audiobooksOutsideLibriVox: { _, _, _, unfiltered in ([doc(), doc()], unfiltered) },
                popularOldTimeRadio: { _, _ in [doc(), doc()] },
                popularMusic: { _, _, _ in [doc(), doc()] },
                popularArchiveMusic: { _, _, _ in [doc(), doc()] },
                metadataOnly: { _ in meta },
                liveness: { _ in liveness }),
            jamendo: JamendoSeam(popularTracks: { _, _, _, _ in [track(), track()] }, clientId: { "witness" }),
            gutenberg: GutenbergSeam(audiobooks: { _, _ in [] }),
            librivox: LibriVoxSeam(newBooks: { _, _ in [book(), book()] }))
    }

    /// Every question throws `offline`.
    static func failing(liveness: DeadCatalogItems.Liveness = .unknown) -> CatalogClients {
        CatalogClients(
            archive: ArchiveSeam(
                popularLibriVoxByLanguage: { _, _, _, _ in throw offline },
                audiobooksOutsideLibriVox: { _, _, _, _ in throw offline },
                popularOldTimeRadio: { _, _ in throw offline },
                popularMusic: { _, _, _ in throw offline },
                popularArchiveMusic: { _, _, _ in throw offline },
                metadataOnly: { _ in throw offline },
                liveness: { _ in liveness }),
            jamendo: JamendoSeam(popularTracks: { _, _, _, _ in throw offline }, clientId: { "witness" }),
            gutenberg: GutenbergSeam(audiobooks: { _, _ in throw offline }),
            librivox: LibriVoxSeam(newBooks: { _, _ in throw offline }))
    }

    /// Every source on, no language filter.
    static let allOn = CatalogGates(librivox: true, archiveBooks: true, gutenberg: true, jamendo: true,
                                    freeAudiobooksArea: true, freeClassical: true, netlabels: true,
                                    languages: [])

    static func items(_ outcome: CatalogLoadOutcome) -> [LibraryItem]? {
        if case .loaded(let items, _) = outcome { return items }
        return nil
    }
}

@MainActor
struct JamendoLoaderWitnessTests {
    typealias W = CatalogLoaderWitness

    @Test("Jamendo: eine Antwort kommt als Eintraege, ein Fehlschlag mit dem geworfenen Grund")
    func answerAndFailure() async {
        let trove = await JamendoLoader.trove(limit: 2, using: W.answering())
        #expect(W.items(trove)?.count == 2)
        #expect(trove == .loaded(items: W.items(trove) ?? [], fetched: 2))

        #expect(await JamendoLoader.trove(limit: 2, using: W.failing()) == .failed(reason: W.offlineReason))
        #expect(W.offlineReason.contains("-1009"), "der Grund ist der des geworfenen Fehlers")
        #expect(await JamendoLoader.shelfPage(shelfKey: "electronic", limit: 12, offset: 0, filter: .none,
                                              using: W.failing()) == .failed(reason: W.offlineReason))

        var cancelled = W.answering()
        cancelled.jamendo.popularTracks = { _, _, _, _ in throw CancellationError() }
        #expect(await JamendoLoader.trove(limit: 2, using: cancelled) == .cancelled)
    }

    @Test("Jamendo-Regale: ein scheiterndes Regal kommt als Fehlschlag, die anderen als Zeilen")
    func shelvesKeepTheirFailures() async throws {
        let failingKey = try #require(CatalogGenreAxis.musicShelves.first?.key)
        let failingTags = CatalogGenreAxis.musicTags(forShelf: failingKey)
        var clients = W.answering()
        clients.jamendo.popularTracks = { _, tags, _, _ in
            if tags == failingTags { throw W.offline }
            return [W.track()]
        }
        let shelves = await JamendoLoader.shelves(using: clients)
        #expect(shelves.failures == [failingKey: W.offlineReason])
        #expect(shelves.rows[failingKey] == nil)
        #expect(shelves.rows.count == CatalogGenreAxis.musicShelves.count - 1)
    }
}

@MainActor
struct ArchiveMusicLoaderWitnessTests {
    typealias W = CatalogLoaderWitness

    @Test("Archiv-Musik: eine Antwort kommt als Eintraege, ein Fehlschlag mit dem geworfenen Grund")
    func answerAndFailure() async throws {
        let area = ArchiveMusicCatalog.classical
        #expect(W.items(await ArchiveMusicLoader.areaPage(area, rows: 2, page: 1, using: W.answering()))?.count == 2)
        let shelfKey = try #require(CatalogGenreAxis.musicShelves.map(\.key)
            .first { !CatalogGenreAxis.musicSubjects(forShelf: $0).isEmpty })
        #expect(W.items(await ArchiveMusicLoader.shelfPage(area, shelfKey: shelfKey, rows: 2, page: 1,
                                                           using: W.answering()))?.count == 2)
        #expect(await ArchiveMusicLoader.areaPage(area, rows: 1, page: 1, using: W.failing())
                == .failed(reason: W.offlineReason))
        #expect(await ArchiveMusicLoader.shelfPage(area, shelfKey: shelfKey, rows: 1, page: 1, using: W.failing())
                == .failed(reason: W.offlineReason))
    }
}

@MainActor
struct ArchiveMetadataLoaderWitnessTests {
    typealias W = CatalogLoaderWitness

    @Test("Archiv-Metadaten: eine Antwort, ein Fehlschlag mit dem geworfenen Grund, und kein Archiv heisst nichts")
    func answerAndFailure() async throws {
        let id = FreeCatalog.archivePrefix + "witness-meta"
        guard case .found(let found) = await ArchiveMetadataLoader.quickMetadata(
            forItemId: id, using: W.answering(meta: try W.meta())) else {
            Issue.record("eine Antwort kam nicht als Metadaten an"); return
        }
        #expect(found.description?.joined == "D")

        guard case .failed(let reason) = await ArchiveMetadataLoader.quickMetadata(forItemId: id, using: W.failing()) else {
            Issue.record("ein Fehlschlag kam nicht als Fehlschlag an"); return
        }
        #expect(reason == W.offlineReason)

        // Asking would throw, and a thrown error would come back as a
        // failure; `.none` therefore means the archive was not asked at all.
        var mustNotAsk = W.answering()
        mustNotAsk.archive.metadataOnly = { _ in throw W.Asked() }
        guard case .none = await ArchiveMetadataLoader.quickMetadata(forItemId: "jam:1", using: mustNotAsk) else {
            Issue.record("fuer einen Nicht-Archiv-Eintrag wurde das Archiv gefragt"); return
        }
    }

    @Test("zurueckgezogen wird gemessen, und der Vermerk landet in der gereichten Ablage")
    func withdrawnIsMeasuredAndNotedWhereHandedIn() async throws {
        let suite = "witness-dead-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = FreeCatalog.archivePrefix + "witness-\(UUID().uuidString)"

        #expect(await ArchiveMetadataLoader.isWithdrawn(itemId: id, using: W.answering(liveness: .dead),
                                                        defaults: defaults))
        #expect(!DeadCatalogItems.marked(defaults: defaults).isEmpty, "der Vermerk steht in der gereichten Ablage")
        #expect(DeadCatalogItems.marked().keys.allSatisfy { !$0.contains("witness-") },
                "der Vermerk landet nicht in der Ablage der App")
        #expect(!(await ArchiveMetadataLoader.isWithdrawn(itemId: id, using: W.failing(liveness: .unknown),
                                                          defaults: defaults)),
                "unerreichbar sagt nichts ueber den Eintrag")
    }
}

@MainActor
struct FreeCatalogLoaderWitnessTests {
    typealias W = CatalogLoaderWitness

    @Test("Entdecken-Reihen: Antworten fuellen die Reihen, Fehlschlaege stehen als Probleme, ohne Netz")
    func answerAndFailure() async throws {
        let suite = "witness-day-\(UUID().uuidString)"
        let dayStore = try #require(UserDefaults(suiteName: suite))
        defer { dayStore.removePersistentDomain(forName: suite) }

        let rows = await FreeCatalogLoader.load(using: W.answering(), gates: W.allOn, dayStore: dayStore)
        #expect(!rows.discoverBooks.isEmpty && !rows.tabBooks.isEmpty)
        #expect(!rows.classical.isEmpty && !rows.netlabels.isEmpty)
        #expect(rows.freeMusic.count == 2)
        #expect(rows.problems.isEmpty, "eine Antwort ist kein Problem: \(rows.problems)")

        let failed = await FreeCatalogLoader.load(using: W.failing(), gates: W.allOn, dayStore: dayStore)
        #expect(failed.problems[.books] == W.offlineReason, "der Grund ist der des geworfenen Fehlers")
        #expect(failed.problems[.classical] == W.offlineReason)
        #expect(failed.problems[.netlabels] == W.offlineReason)
        // The Jamendo row answered in the first pass and kept its day; the
        // second pass reads the day and asks nothing, as the live row does.
        #expect(failed.freeMusic.count == 2, "der Tag traegt die erste gute Antwort")
    }

    /// Invariant 3: the day's Jamendo answer lands in the handed-in store,
    /// and a run with stand-ins leaves the app's own store as it was.
    @Test("ein Lauf mit Attrappen beruehrt den Tages-Speicher der App nicht")
    func aStandInRunLeavesTheAppStoreAlone() async throws {
        let suite = "witness-day-\(UUID().uuidString)"
        let dayStore = try #require(UserDefaults(suiteName: suite))
        defer { dayStore.removePersistentDomain(forName: suite) }
        let appKey = "catalogShelfStock"
        let before = UserDefaults.standard.data(forKey: appKey)

        _ = await FreeCatalogLoader.load(using: W.answering(), gates: W.allOn, dayStore: dayStore)

        #expect(dayStore.data(forKey: appKey) != nil, "die gute Antwort steht im gereichten Speicher")
        #expect(UserDefaults.standard.data(forKey: appKey) == before, "der Speicher der App ist unberuehrt")

        var failing = W.failing()
        failing.jamendo.clientId = { nil }
        let keyless = await FreeCatalogLoader.load(using: failing, gates: W.allOn, dayStore: dayStore)
        #expect(keyless.freeMusicProblem != nil, "ohne Schluessel steht ein Satz, keine leere Reihe")
    }
}

@MainActor
struct CatalogSourceLoaderWitnessTests {
    typealias W = CatalogLoaderWitness

    @Test("Quellen-Reihen: Antworten fuellen die Reihen, Fehlschlaege tragen den geworfenen Grund")
    func answerAndFailure() async {
        let rows = await CatalogSourceLoader.load(using: W.answering(), gates: W.allOn)
        #expect(!rows.librivoxNew.isEmpty && !rows.librivoxPopular.isEmpty)
        #expect(!rows.archiveBooks.isEmpty && !rows.oldTimeRadio.isEmpty)
        #expect(rows.failures.isEmpty, "eine Antwort ist kein Fehlschlag: \(rows.failures)")

        let failed = await CatalogSourceLoader.load(using: W.failing(), gates: W.allOn)
        for source in [CatalogSource.librivox, .archiveBooks, .gutenberg, .oldTimeRadio] {
            #expect(failed.failures[source] == W.offlineReason, "\(source.rawValue) traegt den geworfenen Grund")
        }
    }
}

@MainActor
struct CatalogPopularSourceWitnessTests {
    typealias W = CatalogLoaderWitness

    @Test("Beliebt-Seite: eine Antwort kommt als Seite, ein Fehlschlag mit dem geworfenen Grund")
    func answerAndFailure() async {
        guard case .loaded(let items, _, _) = await CatalogPopularSource.page(
            source: .oldTimeRadio, page: 1, rows: 2, unfiltered: false, using: W.answering(), languages: []) else {
            Issue.record("eine Antwort kam nicht als Seite an"); return
        }
        // Both stand-in records pass the curation (no LibriVox duplicate,
        // no exclusion), so both must arrive; zero would prove nothing.
        #expect(items.count == 2, "die kuratierte Antwort kommt nicht als Eintraege an")
        guard case .failed(let reason) = await CatalogPopularSource.page(
            source: .librivox, page: 1, rows: 2, unfiltered: false, using: W.failing(), languages: []) else {
            Issue.record("ein Fehlschlag kam nicht als Fehlschlag an"); return
        }
        #expect(reason == W.offlineReason)
    }
}
#endif
