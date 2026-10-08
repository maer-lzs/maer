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
        #expect(BookFinishMark.step(isCatalog: true, target: true, fetch: .failed, knownDuration: 600, knownFraction: 0.2)
                == .local(position: 600, duration: 600), "a catalogue title is marked on the device, whatever the server said")
        #expect(BookFinishMark.step(isCatalog: true, target: true, fetch: .failed, knownDuration: 0, knownFraction: 0)
                == .local(position: 1, duration: 0), "a finished mark without a known length still stands past the start")
        #expect(BookFinishMark.step(isCatalog: true, target: false, fetch: .failed, knownDuration: 600, knownFraction: 1)
                == .local(position: 0, duration: 600))
        #expect(BookFinishMark.step(isCatalog: false, target: true, fetch: .fresh(duration: 900, currentTime: 300),
                                    knownDuration: 800, knownFraction: 0.5)
                == .send(currentTime: 900, duration: 900), "the server's own numbers lead, the whole record goes")
        #expect(BookFinishMark.step(isCatalog: false, target: false, fetch: .fresh(duration: 900, currentTime: 300),
                                    knownDuration: 800, knownFraction: 0.5)
                == .send(currentTime: 300, duration: 900), "unmarking keeps the real position")
        #expect(BookFinishMark.step(isCatalog: false, target: false, fetch: .offline, knownDuration: 800, knownFraction: 0.5)
                == .queue(currentTime: 400, duration: 800), "offline the decision is queued with the known values")
        #expect(BookFinishMark.step(isCatalog: false, target: true, fetch: .failed, knownDuration: 800, knownFraction: 0.5)
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

    @Test("die Buch-Geste schreibt nur noch die Tuer, beide Flaechen rufen sie", .needsTheSources)
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
    }
}
#endif
