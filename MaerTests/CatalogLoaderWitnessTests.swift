// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Each catalogue loader runs offline with a stand-in client: an answer
/// arrives as items, and a failure arrives as `.failed(reason:)` with the
/// reason of the error the stand-in threw.
nonisolated enum CatalogLoaderWitness {
    struct Asked: Error {}

    /// The error every stand-in throws, and the reason it must come back as.
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
        let answering = JamendoLoader.Client { _, _, _, _ in [W.track(), W.track()] }
        let trove = await JamendoLoader.trove(limit: 2, using: answering)
        #expect(W.items(trove)?.count == 2)
        #expect(trove == .loaded(items: W.items(trove) ?? [], fetched: 2))

        let failing = JamendoLoader.Client { _, _, _, _ in throw W.offline }
        #expect(await JamendoLoader.trove(limit: 2, using: failing) == .failed(reason: W.offlineReason))
        #expect(W.offlineReason.contains("-1009"), "der Grund ist der des geworfenen Fehlers")
        #expect(await JamendoLoader.shelfPage(shelfKey: "electronic", limit: 12, offset: 0, filter: .none,
                                              using: failing) == .failed(reason: W.offlineReason))

        let cancelled = JamendoLoader.Client { _, _, _, _ in throw CancellationError() }
        #expect(await JamendoLoader.trove(limit: 2, using: cancelled) == .cancelled)
    }

    @Test("Jamendo-Regale: ein scheiterndes Regal kommt als Fehlschlag, die anderen als Zeilen")
    func shelvesKeepTheirFailures() async throws {
        let failingKey = try #require(CatalogGenreAxis.musicShelves.first?.key)
        let failingTags = CatalogGenreAxis.musicTags(forShelf: failingKey)
        let client = JamendoLoader.Client { _, tags, _, _ in
            if tags == failingTags { throw W.offline }
            return [W.track()]
        }
        let shelves = await JamendoLoader.shelves(using: client)
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
        let answering = ArchiveMusicLoader.Client(popularMusic: { _, _, _ in [W.doc()] },
                                                  popularArchiveMusic: { _, _, _ in [W.doc(), W.doc()] })
        #expect(W.items(await ArchiveMusicLoader.areaPage(area, rows: 1, page: 1, using: answering))?.count == 1)
        let shelfKey = try #require(CatalogGenreAxis.musicShelves.map(\.key)
            .first { !CatalogGenreAxis.musicSubjects(forShelf: $0).isEmpty })
        #expect(W.items(await ArchiveMusicLoader.shelfPage(area, shelfKey: shelfKey, rows: 2, page: 1,
                                                           using: answering))?.count == 2)

        let failing = ArchiveMusicLoader.Client(popularMusic: { _, _, _ in throw W.offline },
                                                popularArchiveMusic: { _, _, _ in throw W.offline })
        #expect(await ArchiveMusicLoader.areaPage(area, rows: 1, page: 1, using: failing)
                == .failed(reason: W.offlineReason))
        #expect(await ArchiveMusicLoader.shelfPage(area, shelfKey: shelfKey, rows: 1, page: 1, using: failing)
                == .failed(reason: W.offlineReason))
    }
}

@MainActor
struct ArchiveMetadataLoaderWitnessTests {
    typealias W = CatalogLoaderWitness

    static func meta() throws -> ArchiveOrgClient.MetadataResponse.Meta {
        try JSONDecoder().decode(ArchiveOrgClient.MetadataResponse.Meta.self,
                                 from: Data(#"{"title":"T","description":"D"}"#.utf8))
    }

    @Test("Archiv-Metadaten: eine Antwort, ein Fehlschlag mit dem geworfenen Grund, und kein Archiv heisst nichts")
    func answerAndFailure() async throws {
        let id = FreeCatalog.archivePrefix + "witness-meta"
        let meta = try Self.meta()
        let answering = ArchiveMetadataLoader.Client(metadataOnly: { _ in meta }, liveness: { _ in .alive })
        guard case .found(let found) = await ArchiveMetadataLoader.quickMetadata(forItemId: id, using: answering) else {
            Issue.record("eine Antwort kam nicht als Metadaten an"); return
        }
        #expect(found.description?.joined == "D")

        let failing = ArchiveMetadataLoader.Client(metadataOnly: { _ in throw W.offline }, liveness: { _ in .unknown })
        guard case .failed(let reason) = await ArchiveMetadataLoader.quickMetadata(forItemId: id, using: failing) else {
            Issue.record("ein Fehlschlag kam nicht als Fehlschlag an"); return
        }
        #expect(reason == W.offlineReason)

        // Asking would throw, and a thrown error would come back as a
        // failure; `.none` therefore means the archive was not asked at all.
        let mustNotAsk = ArchiveMetadataLoader.Client(metadataOnly: { _ in throw W.Asked() },
                                                      liveness: { _ in .alive })
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

        let dead = ArchiveMetadataLoader.Client(metadataOnly: { _ in nil }, liveness: { _ in .dead })
        #expect(await ArchiveMetadataLoader.isWithdrawn(itemId: id, using: dead, defaults: defaults))
        #expect(!DeadCatalogItems.marked(defaults: defaults).isEmpty, "der Vermerk steht in der gereichten Ablage")
        #expect(DeadCatalogItems.marked().keys.allSatisfy { !$0.contains("witness-") },
                "der Vermerk landet nicht in der Ablage der App")

        let unreachable = ArchiveMetadataLoader.Client(metadataOnly: { _ in nil }, liveness: { _ in .unknown })
        #expect(!(await ArchiveMetadataLoader.isWithdrawn(itemId: id, using: unreachable, defaults: defaults)),
                "unerreichbar sagt nichts ueber den Eintrag")
    }
}
#endif
