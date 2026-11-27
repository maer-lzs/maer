// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Synchronization
@testable import Maer

/// The small points of the collected slice, one witness each.
@MainActor
struct SammelGruenTests {
    @Test("a resume request is taken by one caller at a time; a second while it runs comes back")
    func resumeTakenOnce() {
        ResumeRequest.release()
        let first = ResumeRequest.take(), second = ResumeRequest.take()
        ResumeRequest.release()
        let third = ResumeRequest.take()
        ResumeRequest.release()
        #expect(first)
        #expect(!second, "two callers ran the same request")
        #expect(third)
    }

    @Test("Fence: the resume takes the request before it waits and gives it back after", .needsTheSources)
    func resumeFence() throws {
        let view = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/LibraryView.swift"), encoding: .utf8))
        let start = try #require(view.range(of: "private func handlePendingResumeRequest() async {"))
        let body = view[start.upperBound...].prefix(2_400)
        let take = try #require(body.range(of: "guard ResumeRequest.take() else"))
        let wait = try #require(body.range(of: "await playerCoordinator.resume("))
        #expect(take.lowerBound < wait.lowerBound)
        #expect(body.contains("defer { ResumeRequest.release() }"))
    }

    @Test("a Gutenberg title with its subtitle after a line break shows only the title on tiles")
    func tileTitle() {
        #expect(FreeCatalog.tileTitle("The Raven\nA Poem in Five Parts") == "The Raven")
        #expect(FreeCatalog.tileTitle("  Plain title ") == "Plain title")
        let book = GutenbergClient.Book(id: 17, title: "The Raven\nA Poem in Five Parts", authors: nil, languages: ["en"],
                                        formats: ["audio/mpeg": "https://www.gutenberg.org/files/17/17-m/17-m-001.mp3"], subjects: nil)
        #expect(FreeCatalogProvider.shared.remember(gutenberg: book)?.title == "The Raven")
        // The kept stock, the way of the main rows, too.
        let doc = ArchivePopularDoc(identifier: "gut:17", title: ArchiveStringList(["The Raven\nA Poem in Five Parts"]),
                                    creator: nil, downloads: 1, runtime: nil, licenseurl: nil, year: nil, subject: nil, collection: nil)
        #expect(FreeCatalogProvider.shared.remember(popular: doc)?.title == "The Raven", "a tile of the kept stock shows the subtitle")
    }

    @Test("the shorthand fence catches the forms the core found")
    func shorthandForms() {
        for form in ["5b-4", "8f-3", "D-12", "A-591", "P5-2", "G20-2"] {
            #expect(!ProjectFileIntegrityTests.letterShorthands(in: "see \(form) here").isEmpty, "\(form) slips through")
        }
        #expect(ProjectFileIntegrityTests.letterShorthands(in: "UTF-8 and HTTP-2").isEmpty)
    }

    @Test("a service without a catalogue is asked once a day, not once per source")
    func noCatalogOnce() async throws {
        let store = try await CatalogRowStore(connection: SQLiteConnection(path: ":memory:"))
        let asked = Mutex(0)
        let ask: CatalogIndexRun.Ask = { _ in asked.withLock { $0 += 1 }; return .absent }
        await CatalogIndexRun.runIfDue(store: store, ask: ask, sources: CatalogIndexSource.allCases)
        await CatalogIndexRun.runIfDue(store: store, ask: ask, sources: CatalogIndexSource.allCases)
        #expect(asked.withLock { $0 } == 1, "asked \(asked.withLock { $0 }) times")
    }

    @Test("the kept place is written again only when the part or the place moved by five seconds")
    func placeWritesSeldom() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("place-\(UUID().uuidString).sqlite").path
        let places = EstimatedPlace(database: MaerDatabase(path: path))
        places.note("gut:1", track: 2, offset: 10, atMs: 1)
        places.note("gut:1", track: 2, offset: 11, atMs: 2)
        places.note("gut:1", track: 2, offset: 12, atMs: 3)
        #expect(places.writes == 1, "written \(places.writes) times")
        places.note("gut:1", track: 2, offset: 16, atMs: 4)
        places.note("gut:1", track: 3, offset: 0, atMs: 5)
        #expect(places.writes == 3)
    }

    @Test("Fence: the app has one store of kept places, and the reads behind wait per work", .needsTheSources)
    func onePlaceStoreAndBehindPerWork() throws {
        let player = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/PlayerViewModel.swift"), encoding: .utf8))
        #expect(player.contains("estimatedPlaces: EstimatedPlace = .shared"))
        let works = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/GutenbergWorks.swift"), encoding: .utf8))
        #expect(works.contains("private var behind: [String: Task<Void, Never>] = [:]"))
        #expect(works.contains("await behind[id]?.value"))
    }
}
#endif
