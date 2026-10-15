// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import Maer

/// Nur eine Kachel, die stehen bleibt, fragt das Netz: die Frist zaehlt ab
/// dem Erscheinen, eine Kachel, die vorher verschwindet, fragt nicht, und
/// Speicher und Platte antworten ohne Frist.
struct TileDwellTests {
    @Test("Regel: 0,4 s fuer ein Cover aus dem Netz, 0,8 s fuer Dauer, Metadaten, Bild und Logo; ausserhalb einer Kachel wartet nichts")
    func outsideAStayNothingWaits() async {
        #expect(TileDwell.cover == .milliseconds(400) && TileDwell.lookup == .milliseconds(800))
        let clock = ContinuousClock()
        let started = clock.now
        #expect(await TileDwell.stood(TileDwell.lookup))
        #expect(started.duration(to: clock.now) < .milliseconds(100), "a question outside a tile waited")
    }

    @Test("Kachel: die Frist zaehlt ab dem Erscheinen, eine zweite Frage derselben Kachel wartet nur den Rest")
    func theStayCountsFromAppearance() async {
        let clock = ContinuousClock()
        let started = clock.now
        await TileDwell.standing {
            #expect(await TileDwell.stood(TileDwell.cover))
            let afterCover = started.duration(to: clock.now)
            #expect(afterCover >= .milliseconds(400) && afterCover < .milliseconds(700), "cover: \(afterCover)")
            #expect(await TileDwell.stood(TileDwell.lookup))
            let afterLookup = started.duration(to: clock.now)
            #expect(afterLookup >= .milliseconds(800) && afterLookup < .milliseconds(1100), "lookup: \(afterLookup)")
            let again = clock.now
            #expect(await TileDwell.stood(TileDwell.cover))
            #expect(again.duration(to: clock.now) < .milliseconds(50), "a stay already stood waited again")
        }
    }

    @Test("Kachel: eine Dauer-Kachel, die vor der Frist verschwindet, fragt nicht; eine, die bleibt, fragt einmal nach 0,8 s")
    func aRuntimeTileThatLeavesAsksNothing() async throws {
        let asks = Count()
        let service = ArchiveRuntimeService(
            wire: .init(files: { _ in asks.add(); return [(format: "VBR MP3", length: "300")] }),
            suiteName: "TileDwellTests-\(UUID().uuidString)")
        let leaving = Task {
            await TileDwell.standing { await service.runtimeSeconds(identifier: "gone") }
        }
        try await Task.sleep(for: .milliseconds(150))
        leaving.cancel()
        #expect(await leaving.value == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(asks.count == 0, "a tile that left asked the network")
        let clock = ContinuousClock()
        let started = clock.now
        let seconds = await TileDwell.standing { await service.runtimeSeconds(identifier: "stays") }
        #expect(seconds == 300)
        #expect(started.duration(to: clock.now) >= .milliseconds(800), "the tile asked before its stay")
        #expect(asks.count == 1)
    }

    @Test("Kachel: ein Feed-Bild wird fuer eine Kachel, die verschwindet, nicht geholt; fuer eine, die bleibt, einmal")
    func aFeedImageTileThatLeavesAsksNothing() async throws {
        let asks = Count()
        let service = FeedArtworkService(suite: "TileDwellTests-\(UUID().uuidString)")
        let fetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse?) = { _ in
            asks.add()
            throw URLError(.timedOut)
        }
        let leaving = Task {
            await TileDwell.standing { await service.artworkURL(feedURL: "https://feeds.example/gone.xml", fetch: fetch) }
        }
        try await Task.sleep(for: .milliseconds(150))
        leaving.cancel()
        _ = await leaving.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(asks.count == 0, "a tile that left asked the feed")
        let clock = ContinuousClock()
        let started = clock.now
        _ = await TileDwell.standing { await service.artworkURL(feedURL: "https://feeds.example/stays.xml", fetch: fetch) }
        #expect(started.duration(to: clock.now) >= .milliseconds(800), "the tile asked before its stay")
        #expect(asks.count == 1)
    }

    @Test("Kachel: ein Cover aus dem Netz wird fuer eine Kachel, die verschwindet, nicht geholt; fuer eine, die bleibt, nach 0,4 s")
    func aCoverTileThatLeavesAsksNothing() async throws {
        // A 404 is absent for the cover door and asked once. A 503 would run
        // the door's retry ladder after the stay, which is not what this
        // case measures and cost it seconds.
        let stand = try await BulkImportTests.Stand.start(.answer(status: 404, body: Data()))
        defer { stand.stop() }
        let gone = URL(string: "http://127.0.0.1:\(stand.port)/gone-\(UUID().uuidString).png")!
        let leaving = Task {
            await TileDwell.standing { await Artwork.image(for: gone, thumbnail: 100) }
        }
        try await Task.sleep(for: .milliseconds(150))
        leaving.cancel()
        _ = await leaving.value
        #expect(await stand.settledCount(expected: 0) == 0, "a tile that left fetched its cover")
        let stays = URL(string: "http://127.0.0.1:\(stand.port)/stays-\(UUID().uuidString).png")!
        let clock = ContinuousClock()
        let started = clock.now
        _ = await TileDwell.standing { await Artwork.image(for: stays, thumbnail: 100) }
        #expect(started.duration(to: clock.now) >= .milliseconds(400), "the tile fetched before its stay")
        #expect(await stand.settledCount(expected: 1) >= 1, "the tile that stayed never asked")
    }

    @Test("Flug: eine fuer die Sitzung gehaltene Antwort kommt ohne Frist, und die Metadaten-Tueren fragen sie vor der Frist", .needsTheSources)
    func aKeptAnswerWaitsNothing() async throws {
        let flights = CoalescedFlights<Int>(capacity: FlightCapacity(entries: 4, bytes: 1000))
        #expect(await flights.kept(for: "k") == nil)
        #expect(try await flights.value(for: "k") { (7, 1) } == 7)
        #expect(await flights.kept(for: "k") == 7, "the answer was not kept")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = SyncContractFenceTests.stripped(try String(contentsOf: root.appendingPathComponent("Sources/Networking/FreeCatalogClients.swift"), encoding: .utf8))
        for flights in ["metadataOnlyFlights", "metadataFlights"] {
            let kept = try #require(text.range(of: "\(flights).kept(for: identifier)"), "\(flights) asks no kept answer")
            let stood = try #require(text[kept.upperBound...].range(of: "TileDwell.stood("), "\(flights) has no stay after the kept answer")
            let between = text[kept.upperBound..<stood.lowerBound]
            #expect(!between.contains("\(flights).value(for:"), "\(flights) flies before the stay")
        }
    }

    /// The places where a tile's question reaches the network: each stays
    /// first. Every site counts exactly; one fewer is a network site
    /// without a stay, and that must tear.
    nonisolated static let networkSites: [String: (count: Int, reason: String)] = [
        "Artwork.swift": (1, "the cover door, before the first network fetch"),
        "ImageCache.swift": (1, "the loaded picture of the radio tiles, before the fetch"),
        "ArchiveRuntimeService.swift": (1, "the runtime, before its flight"),
        "FreeCatalogClients.swift": (2, "metadata and metadataOnly, before their flights"),
        "FeedArtworkService.swift": (1, "the feed image, after the caches"),
        "ArtistPortraitService.swift": (1, "the portrait chain, after the caches"),
        "RadioLogoService.swift": (1, "the logo chain, after the caches"),
    ]

    /// The tiles that mark their questions. A tile that does not is a tile
    /// that asks while it flies past.
    nonisolated static let tileSites: [String: (count: Int, reason: String)] = [
        "CachedAsyncImage.swift": (1, "every thumbnail cell, the rows and tiles"),
        "FeedArtwork.swift": (2, "the feed image and the catalog runtime"),
        "MusicBrowseViews.swift": (1, "the artist portrait"),
        "RadioArtwork.swift": (1, "the station tile, not the hero"),
        "CatalogTrackCell.swift": (1, "the track row's metadata"),
        "PlayQueueView.swift": (1, "the queue row's metadata"),
    ]

    @Test("Zaun: jede Netzstelle einer Kachel-Frage steht erst, jede Kachel markiert ihre Fragen, beide Bestaende fallen nur", .needsTheSources)
    func everyTileQuestionStandsFirst() throws {
        let network = StockDrift.findings(counts: try Self.sites(of: "TileDwell.stood("), stock: Self.networkSites.mapValues(\.count))
        #expect(network.isEmpty, "TileDwell.stood(: \(network)")
        let tiles = StockDrift.findings(counts: try Self.sites(of: "TileDwell.standing"), stock: Self.tileSites.mapValues(\.count))
        #expect(tiles.isEmpty, "TileDwell.standing: \(tiles)")
    }

    /// The sites of `token` per file, outside the type itself.
    private static func sites(of token: String) throws -> [String: Int] {
        var seen: [String: Int] = [:]
        for file in ProjectFileIntegrityTests.sourceFiles() where file.lastPathComponent != "TileDwell.swift" {
            let text = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            let sites = text.components(separatedBy: token).count - 1
            if sites > 0 { seen[file.lastPathComponent, default: 0] += sites }
        }
        return seen
    }

    nonisolated final class Count: Sendable {
        private let lock = NSLock()
        nonisolated(unsafe) private var value = 0
        var count: Int { lock.withLock { value } }
        func add() { lock.withLock { value += 1 } }
    }
}
