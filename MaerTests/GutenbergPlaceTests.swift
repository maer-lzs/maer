// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// While the durations of a Gutenberg work are estimated, the player keeps
/// the part and the place in it on this device, never as a stand that
/// travels; it reads the real durations again at the next occasion; and a
/// download keeps only real durations.
@MainActor
struct GutenbergPlaceTests {
    /// Part one and three seconds, eleven parts of 500 seconds at 32 kbit/s:
    /// part five starts at 2060.44 s.
    static let sizes = [967_056] + Array(repeating: 2_000_000, count: 11)

    static func playerWithEstimates(failFrom: Int? = nil)
        async throws -> (PlayerViewModel, String, GutenbergFirstSoundTests.Reads, EstimatedPlace) {
        let number = 950_000 + Int.random(in: 1...9_999)
        let id = FreeCatalog.gutenbergPrefix + String(number)
        let (works, reads, _) = GutenbergFirstSoundTests.works(number, sizes: sizes, failFrom: failFrom)
        let detail = try await FreeCatalogProvider.shared.gutenbergDetail(itemId: id, works: works)
        let places = EstimatedPlace(database: nil)
        let player = PlayerViewModel(provider: FreeCatalogProvider.shared, localTracks: { _ in [:] }, isOnline: { true },
                                     estimatedPlaces: places)
        await player.load(item: detail)
        return (player, id, reads, places)
    }

    @Test("the rule: the place in a part is the start of the part plus the time in it")
    func rule() {
        let tracks = [ABSAudioTrack(index: 0, startOffset: 0, duration: 60, contentUrl: "a", metadata: nil),
                      ABSAudioTrack(index: 1, startOffset: 60, duration: 500, contentUrl: "b", metadata: nil),
                      ABSAudioTrack(index: 2, startOffset: 560, duration: 500, contentUrl: "c", metadata: nil)]
        #expect(EstimatedPlace.position(of: .init(track: 2, offset: 30), tracks: tracks) == 590)
        #expect(EstimatedPlace.position(of: .init(track: 9, offset: 30), tracks: tracks) == 0, "a part that is not there starts the book")
    }

    @Test("estimated durations: the halt writes no stand, but keeps the part and the place in it on this device")
    func halt() async throws {
        let (player, id, _, places) = try await Self.playerWithEstimates()
        #expect(player.durationsEstimated, "the precondition: estimated")
        await player.seek(to: 2_090.44)
        player.recordHaltStand()
        #expect(ListeningStore.position(id) == nil, "a stand from estimated durations")
        let place = try #require(places.place(id), "the place was not kept")
        #expect(place.track == 5)
        #expect(abs(place.offset - 30) < 1)
        player.stop()
    }

    @Test("a new start with durations still estimated and no stand begins at the kept place")
    func startFromThePlace() async throws {
        let (player, id, _, places) = try await Self.playerWithEstimates()
        player.stop()
        places.note(id, track: 5, offset: 30, atMs: 1)
        let again = PlayerViewModel(provider: FreeCatalogProvider.shared, localTracks: { _ in [:] }, isOnline: { true },
                                    estimatedPlaces: places)
        await again.load(item: try await FreeCatalogProvider.shared.fetchItemDetail(itemId: id))
        #expect(again.durationsEstimated)
        #expect(abs(again.currentTime - 2_090.44) < 1, "the start began at \(again.currentTime)")
        again.stop()
    }

    @Test("taking the real durations turns the place into a stand that travels, and the place goes")
    func adoption() async throws {
        let (player, id, _, places) = try await Self.playerWithEstimates()
        await player.seek(to: 2_090.44)
        player.recordHaltStand()
        #expect(places.place(id) != nil)
        #expect(await player.realDurationsForAMark(id))
        #expect(!player.durationsEstimated)
        let stand = try #require(ListeningStore.position(id), "no stand after the real durations")
        #expect(abs(stand - 2_090.44) < 1)
        #expect(places.place(id) == nil, "the place stayed")
        player.stop()
    }

    @Test("a real stand goes first: the start takes it and the place goes")
    func standFirst() async throws {
        let (player, id, _, places) = try await Self.playerWithEstimates()
        player.stop()
        places.note(id, track: 5, offset: 30, atMs: 1)
        ListeningStore.record(id, position: 100, duration: 5_560, atMs: Date().timeIntervalSince1970 * 1000)
        let again = PlayerViewModel(provider: FreeCatalogProvider.shared, localTracks: { _ in [:] }, isOnline: { true },
                                    estimatedPlaces: places)
        await again.load(item: try await FreeCatalogProvider.shared.fetchItemDetail(itemId: id))
        #expect(abs(again.currentTime - 100) < 1)
        #expect(places.place(id) == nil)
        again.stop()
    }

    @Test("reads behind that failed start again at the next occasion, without a start, and the real durations are taken")
    func readAgain() async throws {
        let (player, id, reads, _) = try await Self.playerWithEstimates(failFrom: 3)
        // Let the failing reads behind finish.
        for _ in 0..<50 where reads.count < Self.sizes.count - 3 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(player.durationsEstimated, "the precondition: the reads behind failed")
        reads.failFrom = nil
        await player.readRealDurationsAgain(by: "network back")
        #expect(!player.durationsEstimated, "the occasion did not read again")
        #expect(StandWrite.allowed(itemId: id, provider: FreeCatalogProvider.shared))
        player.stop()
    }

    @Test("Fence: the occasions ask for the real durations again: the network back, the return to the front, the next part", .needsTheSources)
    func occasions() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        #expect(try code("Sources/Views/LibraryView.swift").contains("readRealDurationsAgain(by: \"network back\")"))
        #expect(try code("Sources/ViewModels/AppHousekeeping.swift").contains("readRealDurationsAgain(by: \"scene active\")"))
        #expect(try code("Sources/ViewModels/PlayerViewModel.swift").contains("readRealDurationsAgain(by: \"next part\")"))
    }

    @Test("Fence: the place never travels: only its own store and the table list name it", .needsTheSources)
    func placeStaysHere() throws {
        let sources = SourceTree.root.appendingPathComponent("Sources")
        let files = try FileManager.default.subpathsOfDirectory(atPath: sources.path).filter { $0.hasSuffix(".swift") }
        for file in files where !file.hasSuffix("EstimatedPlace.swift") && !file.hasSuffix("KeyedRowStore.swift") {
            let text = SyncContractFenceTests.stripped(try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8))
            // The table case, not the player's store of the places.
            let table = text.range(of: #"\.estimatedPlace(?![A-Za-z])"#, options: .regularExpression)
            #expect(table == nil && !text.contains("estimated_place"), "\(file) reaches the place")
        }
    }

    /// Says estimated, and its real durations cannot be read.
    final class EstimatingProvider: AudioProvider {
        var resolves = false
        var providerId: String { "estimating" }
        var keepsMarksOnDevice: Bool { true }
        var capabilities: ProviderCapabilities { [] }
        var streamAuthHeaders: [String: String] { [:] }
        func estimatesDurations(itemId: String, beforeTrack index: Int) -> Bool { true }
        func resolveDurations(itemId: String) async -> Bool { resolves }
        func fetchLibraries() async throws -> [ABSLibrary] { [] }
        func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] { [] }
        func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail { throw GutenbergUnavailable() }
        func coverURL(forItemId itemId: String) -> URL? { nil }
        func streamURL(forContentPath contentPath: String) -> URL? { nil }
        func fetchAllProgress() async throws -> [String: BookProgress] { [:] }
        func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}
        func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
        func createBookmark(itemId: String, time: Double, title: String) async throws {}
        func deleteBookmark(itemId: String, time: Double) async throws {}
    }

    @Test("a download whose real durations cannot be read keeps no detail and fails with the sentence of Gutenberg")
    func downloadFails() async {
        let detail = LibraryItemDetail(id: "gut:1", media: LibraryItemMedia(metadata: nil, duration: 10, chapters: nil, tracks: nil),
                                       userMediaProgress: nil)
        do {
            _ = try await DownloadManager.detailToKeep(detail, provider: EstimatingProvider())
            Issue.record("the estimated detail was kept")
        } catch {
            #expect(error as? GutenbergUnavailable != nil)
            #expect(ErrorSentence.of(error) == String(localized: "Gutenberg is not answering right now."))
        }
    }

    @Test("Fence: the download keeps its detail only through the one question", .needsTheSources)
    func downloadAsks() throws {
        let manager = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/DownloadManager.swift"), encoding: .utf8))
        let save = try #require(manager.range(of: "await saveDetail(item)"))
        #expect(manager[..<save.lowerBound].suffix(400).contains("try await Self.detailToKeep("))
    }
}
#endif
