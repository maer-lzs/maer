// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// "Mark as finished" for a book goes through one door, from the detail page
/// and from the tile menu alike; a catalogue title's mark lands on the device.
@MainActor
struct BookFinishMarkTests {
    @Test("die Geste geht je Titel an ihren Ort: Katalog lokal, Server ganz, offline in die Schlange, ein Fehler schreibt nichts")
    func eachTitleGoesToItsPlace() {
        #expect(BookFinishMark.step(keptHere: true, target: true, fetch: .failed, knownDuration: 600, knownFraction: 0.2)
                == .local(position: 600, duration: 600), "a catalogue title is marked on the device, whatever the server said")
        #expect(BookFinishMark.step(keptHere: true, target: true, fetch: .failed, knownDuration: 0, knownFraction: 0)
                == .local(position: 1, duration: 0), "a finished mark without a known length still stands past the start")
        #expect(BookFinishMark.step(keptHere: true, target: false, fetch: .failed, knownDuration: 600, knownFraction: 1)
                == .local(position: 0, duration: 600))
        #expect(BookFinishMark.step(keptHere: false, target: true, fetch: .fresh(duration: 900, currentTime: 300),
                                    knownDuration: 800, knownFraction: 0.5)
                == .send(currentTime: 900, duration: 900), "the server's own numbers lead, the whole record goes")
        #expect(BookFinishMark.step(keptHere: false, target: false, fetch: .fresh(duration: 900, currentTime: 300),
                                    knownDuration: 800, knownFraction: 0.5)
                == .send(currentTime: 300, duration: 900), "unmarking keeps the real position")
        #expect(BookFinishMark.step(keptHere: false, target: false, fetch: .offline, knownDuration: 800, knownFraction: 0.5)
                == .queue(currentTime: 400, duration: 800), "offline the decision is queued with the known values")
        #expect(BookFinishMark.step(keptHere: false, target: true, fetch: .failed, knownDuration: 800, knownFraction: 0.5)
                == .refuse)
    }

    @Test("als gehoert markiert, steht der Hoerstand eines Katalog-Titels auf dem Geraet, von jeder Flaeche aus")
    func aCatalogueMarkLandsOnTheDevice() async {
        let id = FreeCatalog.librivoxPrefix + "finish-\(UUID().uuidString)"
        defer { ListeningStore.forgetUserDeleted(id) }
        let entry = LibraryEntry(item: LibraryItem(id: id, media: nil, addedAt: nil), progress: nil)
        let progress = BookProgress(fraction: 0.5, isFinished: false, lastUpdate: 0, currentTime: 600)
        #expect(ListeningStore.mark(id) == nil, "the title carries a mark before the gesture, the case measures nothing")
        let outcome = await BookFinishMark.apply(entry, target: true, progress: progress,
                                                 provider: FreeCatalogProvider.shared,
                                                 coordinator: PlayerCoordinator(provider: MockProvider()),
                                                 libraryViewModel: nil)
        #expect(outcome.step == .local(position: 600, duration: 600))
        #expect(outcome.reason == nil)
        #expect(ListeningStore.mark(id)?.position == 600, "the mark went where the catalogue writes nothing")
    }

    @Test("nach einer eingereihten Marke zeigt die Liste sie sofort, ohne Netz und ohne weiteren Anlass")
    func theListShowsAQueuedMarkAtOnce() async {
        let id = "finish-witness-\(UUID().uuidString)"
        let provider = MockProvider()
        provider.failDetailOffline = true
        let library = LibraryViewModel(provider: provider)
        let item = LibraryItem(id: id, media: LibraryItemMedia(
            metadata: LibraryItemMetadata(title: id, authorName: nil, narratorName: nil,
                                          seriesName: nil, genres: nil, publishedYear: nil, description: nil),
            duration: 100, chapters: nil, tracks: nil), addedAt: nil)
        let started = BookProgress(fraction: 0.5, isFinished: false,
                                   lastUpdate: Date().timeIntervalSince1970 * 1000, currentTime: 50)
        library._seedForUITest([LibraryEntry(item: item, progress: started)])
        defer {
            let pending = SyncQueue.shared.pendingUpdate(itemId: id)
            Task { await SyncQueue.shared.remove(itemId: id, ifStill: pending) }
        }
        #expect(library.continueAll.contains { $0.id == id }, "the started book is not in the list, the case measures nothing")
        let outcome = await BookFinishMark.apply(LibraryEntry(item: item, progress: started), target: true,
                                                 progress: started, provider: provider,
                                                 coordinator: PlayerCoordinator(provider: provider),
                                                 libraryViewModel: library)
        #expect(outcome.step == .queue(currentTime: 100, duration: 100), "offline the mark is queued")
        #expect(!library.continueAll.contains { $0.id == id }, "the finished book still stands in the list")
    }

    /// A server title's source: it answers with fresh numbers and writes,
    /// or refuses the write with `writeError`. Counts the writes and keeps
    /// the last flag. It carries no capability at all, like Jellyfin and
    /// Subsonic: whether a mark is sent is the source's own answer.
    private final class AnsweringProvider: AudioProvider {
        let keepsMarksOnDevice: Bool
        var writeError: Error?
        var writes = 0
        var lastFinished: Bool?
        init(keepsMarksOnDevice: Bool = false, writeError: Error? = nil) {
            self.keepsMarksOnDevice = keepsMarksOnDevice
            self.writeError = writeError
        }
        var providerId: String { "answering" }
        var capabilities: ProviderCapabilities { [] }
        var streamAuthHeaders: [String: String] { [:] }
        func fetchLibraries() async throws -> [ABSLibrary] { [] }
        func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] { [] }
        func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
            LibraryItemDetail(id: itemId, media: BookFinishMarkTests.media(itemId),
                              userMediaProgress: MediaProgress(currentTime: 300, duration: 900, progress: nil,
                                                               isFinished: false, lastUpdate: nil))
        }
        func coverURL(forItemId itemId: String) -> URL? { nil }
        func streamURL(forContentPath contentPath: String) -> URL? { nil }
        func fetchAllProgress() async throws -> [String: BookProgress] { [:] }
        func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {
            writes += 1
            lastFinished = isFinished
            if let writeError { throw writeError }
        }
        func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
        func createBookmark(itemId: String, time: Double, title: String) async throws {}
        func deleteBookmark(itemId: String, time: Double) async throws {}
    }

    nonisolated static func media(_ id: String) -> LibraryItemMedia {
        LibraryItemMedia(metadata: LibraryItemMetadata(title: id, authorName: nil, narratorName: nil, seriesName: nil,
                                                       genres: nil, publishedYear: nil, description: nil),
                         duration: 900, chapters: nil, tracks: nil)
    }

    private func book(_ prefix: String) -> LibraryEntry {
        let id = "\(prefix)-\(UUID().uuidString)"
        return LibraryEntry(item: LibraryItem(id: id, media: Self.media(id), addedAt: nil), progress: nil)
    }

    private func clearQueued(_ id: String) async {
        let pending = SyncQueue.shared.pendingUpdate(itemId: id)
        await SyncQueue.shared.remove(itemId: id, ifStill: pending)
        PlayQueue.shared.remove(id)
    }

    @Test("eine gesendete Marke ist bei 403, 404 und 410 eine Verweigerung mit Satz; die Schlange laesst nur 404 und 410 fallen")
    func theRefusalRules() {
        #expect(SyncRules.refusesTheMark(status: 403))
        #expect(SyncRules.refusesTheMark(status: 404))
        #expect(SyncRules.refusesTheMark(status: 410))
        #expect(!SyncRules.refusesTheMark(status: 401), "the access, not the content: queued for after the sign-in")
        #expect(!SyncRules.refusesTheMark(status: 429))
        #expect(!SyncRules.refusesTheMark(status: 503))
        #expect(SyncRules.queueDrops(status: 404))
        #expect(SyncRules.queueDrops(status: 410))
        #expect(!SyncRules.queueDrops(status: 403), "a 403 can come from in front of the server and says nothing about the title")
        #expect(!SyncRules.queueDrops(status: 401))
        #expect(!SyncRules.queueDrops(status: 503))
        #expect(SyncQueue.httpStatus(of: APIError.http(403, "")) == 403)
        #expect(SyncQueue.httpStatus(of: JellyfinClient.JellyfinError.http(404)) == 404)
        #expect(SyncQueue.httpStatus(of: SubsonicClient.SubsonicError.http(410)) == 410)
        #expect(SyncQueue.httpStatus(of: URLError(.notConnectedToInternet)) == nil)
    }

    @Test("jede Quelle sagt selbst, ob eine Marke bei ihr ankommt: Server senden, lokale Dateien, Kataloge, Feeds und Radio behalten sie")
    func everySourceAnswersWhereItsMarkGoes() {
        let session = AppSession.shared
        let answers: [(id: String, keeps: Bool)] = [
            ("abs-book-id", false), ("jf:book:x", false), ("sub:album:x", false),
            ("local:x", true), (FreeCatalog.librivoxPrefix + "x", true), ("rss:x", true), ("radio:x", true),
        ]
        for answer in answers {
            #expect(session.provider(for: answer.id).keepsMarksOnDevice == answer.keeps, "\(answer.id)")
        }
    }

    @Test("ein Buch einer Quelle ohne Audiobookshelf-Abgleich (Jellyfin, Booksonic) bekommt seine Marke gesendet")
    func aMarkReachesASourceWithoutTheReconcile() async {
        let entry = book("jf:book")
        let provider = AnsweringProvider()
        let outcome = await BookFinishMark.apply(entry, target: true, progress: nil, provider: provider,
                                                 coordinator: PlayerCoordinator(provider: provider), libraryViewModel: nil)
        await clearQueued(entry.id)
        #expect(outcome.step == .send(currentTime: 900, duration: 900), "the mark stayed on the device")
        #expect(provider.writes == 1)
        #expect(provider.lastFinished == true)
    }

    @Test("verweigert der Server den Schrieb inhaltlich, bleibt alles: nichts eingereiht, Als Naechstes unveraendert, der Satz kommt")
    func aRefusedWriteChangesNothing() async {
        let entry = book("refused")
        PlayQueue.shared.playLast(entry.id)
        let provider = AnsweringProvider(writeError: APIError.http(403, "forbidden"))
        let outcome = await BookFinishMark.apply(entry, target: true, progress: nil, provider: provider,
                                                 coordinator: PlayerCoordinator(provider: provider), libraryViewModel: nil)
        let queued = SyncQueue.shared.hasPendingUpdate(itemId: entry.id)
        let stillNext = PlayQueue.shared.contains(entry.id)
        await clearQueued(entry.id)
        #expect(provider.writes == 1, "the precondition: the write was tried")
        #expect(outcome.step == .refuse)
        #expect(outcome.reason != nil, "the person hears nothing")
        #expect(!queued, "a refused mark waits in the queue to be sent again")
        #expect(stillNext, "a refused mark took the title out of Up Next")
    }

    @Test("ein voruebergehender Fehler beim Schrieb reiht die Marke ein und nimmt den Titel aus Als Naechstes")
    func aPassingFailureQueuesTheMark() async {
        let entry = book("passing")
        PlayQueue.shared.playLast(entry.id)
        let provider = AnsweringProvider(writeError: APIError.http(503, "busy"))
        let outcome = await BookFinishMark.apply(entry, target: true, progress: nil, provider: provider,
                                                 coordinator: PlayerCoordinator(provider: provider), libraryViewModel: nil)
        let queued = SyncQueue.shared.pendingUpdate(itemId: entry.id)
        let stillNext = PlayQueue.shared.contains(entry.id)
        await clearQueued(entry.id)
        #expect(outcome.step == .send(currentTime: 900, duration: 900))
        #expect(queued?.isFinished == true, "the mark is lost instead of queued")
        #expect(!stillNext)
    }

    @Test("eine lokale Datei traegt ihre Marke auf dem Geraet, ihre Quelle schreibt nichts")
    func aLocalFileKeepsItsMarkHere() async {
        let entry = book("local:finish")
        defer { ListeningStore.forgetUserDeleted(entry.id) }
        let provider = AnsweringProvider(keepsMarksOnDevice: true)
        let outcome = await BookFinishMark.apply(entry, target: true, progress: nil, provider: provider,
                                                 coordinator: PlayerCoordinator(provider: provider), libraryViewModel: nil)
        #expect(outcome.step == .local(position: 900, duration: 900))
        #expect(provider.writes == 0, "the mark went to a source that writes nothing")
        #expect(ListeningStore.mark(entry.id)?.position == 900, "the mark is gone at the next start")
    }

    @Test("der Player nimmt fuer ein Buch die Tuer: verweigert bleiben Stand und Marke, geschrieben steht die Marke")
    func thePlayerTakesTheDoor() async {
        let entry = book("player")
        let refusing = AnsweringProvider(writeError: APIError.http(404, "gone"))
        let model = PlayerViewModel(provider: refusing)
        model.item = LibraryItemDetail(id: entry.id, media: Self.media(entry.id), userMediaProgress: nil)
        model.duration = 900
        model.currentTime = 300
        let coordinator = PlayerCoordinator(provider: refusing)
        let refusal = await model.markWithTheBookDoor(entry.item, coordinator: coordinator, libraryViewModel: nil)
        let queuedAfterRefusal = SyncQueue.shared.hasPendingUpdate(itemId: entry.id)
        #expect(refusal != nil, "the person hears nothing")
        #expect(!model.isFinished && model.currentTime == 300, "a refused mark moved the player")
        #expect(!queuedAfterRefusal)

        let writing = AnsweringProvider()
        let written = PlayerViewModel(provider: writing)
        written.item = LibraryItemDetail(id: entry.id, media: Self.media(entry.id), userMediaProgress: nil)
        written.duration = 900
        written.currentTime = 300
        let answer = await written.markWithTheBookDoor(entry.item, coordinator: PlayerCoordinator(provider: writing),
                                                       libraryViewModel: nil)
        await clearQueued(entry.id)
        #expect(answer == nil)
        #expect(written.isFinished, "the written mark does not show in the player")
        #expect(writing.writes == 1)
    }

    @Test("die Buch-Geste schreibt nur noch die Tuer, alle drei Flaechen rufen sie", .needsTheSources)
    func onlyTheDoorWritesTheGesture() throws {
        let views = ProjectFileIntegrityTests.sourceTexts(in: ["Sources/Views"])
        #expect(views.count > 100, "der Zaun hat die Ansichten nicht gelesen")
        let writers = views.filter { file in
            let code = SyncContractFenceTests.stripped(file.text)
            return code.contains(".updateProgress(") || code.contains("SyncQueue.shared.enqueue(")
        }.map(\.name)
        #expect(writers.isEmpty, "a view writes a book's mark past the door: \(writers)")
        let callers = views.filter { SyncContractFenceTests.stripped($0.text).contains("BookFinishMark.apply(") }
            .map(\.name).sorted()
        #expect(callers == ["BookDetailScreen.swift", "BookGridComponents.swift"], "\(callers)")
        // The player is the third surface: its model takes the door, and its
        // button hands a book to it.
        let models = ProjectFileIntegrityTests.sourceTexts(in: ["Sources/ViewModels"])
        let modelCallers = models.filter { SyncContractFenceTests.stripped($0.text).contains("BookFinishMark.apply(") }
            .map(\.name).sorted()
        #expect(modelCallers == ["PlayerViewModel+Sync.swift"], "\(modelCallers)")
        let player = SyncContractFenceTests.stripped(try #require(views.first { $0.name == "PlayerView.swift" }).text)
        #expect(player.contains("viewModel.markWithTheBookDoor("), "the player's button does not hand a book to the door")
    }

    /// A refused mark writes nothing, and both surfaces say the door's
    /// sentence: the detail page in its line, the tile menu, closed by the
    /// time the answer comes, in a notice on the cell that hosts it.
    @Test("verweigert der Server die Marke, sagen beide Flaechen den Satz der Tuer", .needsTheSources)
    func bothSurfacesSayARefusedMark() throws {
        let views = ProjectFileIntegrityTests.sourceTexts(in: ["Sources/Views"])
        for name in ["BookDetailScreen.swift", "BookGridComponents.swift"] {
            let code = SyncContractFenceTests.stripped(try #require(views.first { $0.name == name }).text)
            #expect(code.contains("let outcome = await BookFinishMark.apply("), "\(name) drops the outcome")
            #expect(code.contains("outcome.reason"), "\(name) never reads the sentence")
        }
        let grid = SyncContractFenceTests.stripped(try #require(views.first { $0.name == "BookGridComponents.swift" }).text)
        #expect(grid.contains("onRefused: { refusal = $0 }"), "the menu does not hand the sentence to its cell")
        #expect(grid.contains(".alert(Text(verbatim: refusal"), "the cell does not say the sentence")
    }
}
#endif
