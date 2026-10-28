// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import UIKit
import os
@testable import Maer

/// An Audiobookshelf cover has two forms: the grid asks it at its width,
/// the large views unscaled. A download keeps the unscaled one; offline the
/// grid reads it under its former name, reduced to the cell, and forgetting
/// the download takes every stage of the name chain out of the kept folder.
@MainActor
@Suite(.serialized)
struct AbsCoverFormsTests {
    private static func client() -> APIClient {
        APIClient(baseURL: URL(string: "https://abs.example.lan")!, token: "tok")
    }

    private static func jpeg(_ side: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.85) { context in
            for row in stride(from: 0, to: side, by: 6) {
                UIColor(hue: CGFloat(row) / CGFloat(side), saturation: 0.6, brightness: 0.8, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: row, width: side, height: 6))
            }
        }
    }

    @Test("das Raster fragt width=400, die grossen Ansichten raw=1")
    func theGridAsksTheWidthTheLargeViewsTheOriginal() throws {
        let client = Self.client()
        let grid = try #require(client.coverURL(forItemId: "li_1"))
        let large = try #require(client.largeCoverURL(forItemId: "li_1"))
        let items = { (url: URL) in Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []) }
        #expect(items(grid).contains(APIClient.coverWidthName) && !items(grid).contains(APIClient.coverOriginalName))
        #expect(grid.query?.contains("width=\(APIClient.coverGridWidth)") == true)
        #expect(items(large).contains(APIClient.coverOriginalName) && !items(large).contains(APIClient.coverWidthName))
        #expect(ImageCache.shared.testKey(for: grid) != ImageCache.shared.testKey(for: large), "both forms under one name")
    }

    @Test("die Kette frueherer Namen: das Raster liest das gesicherte grosse Bild, dann den Namen von vor 57")
    func theGridReadsTheKeptOriginalThenTheOldName() throws {
        let client = Self.client()
        let grid = try #require(client.coverURL(forItemId: "li_2"))
        let large = try #require(client.largeCoverURL(forItemId: "li_2"))
        let cache = ImageCache.shared
        let names = cache.formerNames(for: grid)
        #expect(names.first == cache.testKey(for: large))
        #expect(names.count == 2)
        #expect(cache.formerNames(for: large) == [names[1]], "the original leads to the name from before 57")
    }

    @Test("offline dekodiert die Rasterzelle das gesicherte grosse Bild verkleinert")
    func offlineTheCellDecodesTheKeptOriginalReduced() async throws {
        let client = Self.client()
        let id = "li_reduced_\(UUID().uuidString)"
        let grid = try #require(client.coverURL(forItemId: id))
        let large = try #require(client.largeCoverURL(forItemId: id))
        let cache = ImageCache.shared
        #expect(cache.testPlacePersistent(Self.jpeg(1600), for: large), "the precondition: the download kept the original")
        defer { cache.testRemovePersistent(named: cache.testKey(for: large)) }
        let cell = try #require(await cache.thumbnail(for: grid, maxPixelSize: 400), "the grid found nothing offline")
        #expect(max(cell.size.width, cell.size.height) * cell.scale <= 400, "the cell holds the full original")
    }

    @Test("nach forget steht keine Stufe der Namenskette mehr im geschuetzten Ordner")
    func forgettingTakesTheWholeChainOutOfTheKeptFolder() throws {
        let client = Self.client()
        let id = "li_forget_\(UUID().uuidString)"
        let grid = try #require(client.coverURL(forItemId: id))
        let large = try #require(client.largeCoverURL(forItemId: id))
        let cache = ImageCache.shared
        let names = cache.formerNames(for: grid)
        let old = try #require(names.last)
        #expect(cache.testPlacePersistent(Self.jpeg(64), for: large))
        #expect(cache.testPlacePersistent(Self.jpeg(64), named: old), "the precondition: a download from before 57")
        Artwork.forget(large)
        #expect(!cache.testIsPersistent(large), "the original stayed kept")
        #expect(!cache.testIsPersistent(named: old), "the name from before 57 stayed kept")
        // The forgotten files went to the purgeable cache, where a cover
        // stays readable; that cache sweeps them by itself.
        #expect(cache.testIsInCache(named: cache.testKey(for: large)) || cache.testIsInCache(named: old))
    }

    @Test("ein Download sichert beide Formen, Fegelauf und forget fragen dieselben", .needsTheSources)
    func theDownloadKeepsBothForms() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/DownloadManager.swift"), encoding: .utf8))
        #expect(code.contains("let grid = provider.coverURL(forItemId: itemId)"))
        #expect(code.contains("for url in Self.keptCoverURLs(grid: grid, large: large) {\n                await Artwork.persist(url)"))
        #expect(code.contains("noteSessionCovers(of: itemId, grid: grid, large: large)"))
        #expect(code.contains("for url in coverURLs(of: itemId, grid: owner.coverURL(forItemId: itemId),"))
        #expect(code.contains("urls += coverURLs(of: itemId, grid: url, large: largeAddress(itemId))"))
        let grid = URL(string: "https://archive.org/services/img/x")!
        let large = URL(string: "https://archive.org/download/x/front.jpg")!
        #expect(DownloadManager.keptCoverURLs(grid: grid, large: large) == [grid, large])
        #expect(DownloadManager.keptCoverURLs(grid: grid, large: grid) == [grid], "one form kept once")
    }

    @Test("Neustart und offline: ein geladener Archiv-Titel zeigt in Raster und grosser Ansicht ein Cover")
    func afterARestartBothFormsStandOffline() async throws {
        let provider = FreeCatalogProvider.shared
        let album = "lva:restart-witness-\(UUID().uuidString)"
        let json = """
            {"files": [{"name": "a.mp3", "length": "60", "format": "VBR MP3", "source": "original", "size": "900000"},
                       {"name": "front.jpg", "format": "JPEG", "source": "original", "size": "120000"}],
             "metadata": {"title": "Witness"}}
            """
        let meta = try ArchiveDecoder.decodeMetadata(Data(json.utf8))
        _ = await provider.releaseSongs(albumId: album) { _ in meta }
        let grid = try #require(provider.coverURL(forItemId: album))
        let original = try #require(provider.largeCoverURL(forItemId: album))
        #expect(grid != original, "the precondition: the session knows the original")
        // The download keeps what `keptCoverURLs` names.
        let cache = ImageCache.shared
        let kept = DownloadManager.keptCoverURLs(grid: grid, large: original)
        for url in kept { #expect(cache.testPlacePersistent(Self.jpeg(300), for: url)) }
        defer { for url in kept { cache.testRemovePersistent(named: cache.testKey(for: url)) } }
        // A restart: the session no longer knows the original.
        provider.testForgetOriginalCovers()
        let large = try #require(provider.largeCoverURL(forItemId: album))
        #expect(await cache.thumbnail(for: grid, maxPixelSize: 400) != nil, "the grid has no cover offline")
        #expect(await cache.image(for: large) != nil, "the large view has no cover offline after a restart")
    }

    /// The process footprint the system counts against the app, in bytes.
    private nonisolated static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// A measurement: twelve grid cells offline, each over a kept original
    /// of 2000 pixels, asked the way the grid asked before (the original's
    /// own address) and the way it asks now (its width, through the former
    /// name). The peak over the baseline stands in the log (`COVERPEAK`).
    @Test("Messung: Speicherspitze, zwoelf Rasterzellen offline, vorher und nachher")
    func offlineGridPeak() async throws {
        let client = Self.client()
        let cache = ImageCache.shared
        let bytes = Self.jpeg(2000)
        var results: [String: UInt64] = [:]
        // Both orders, so the first round's warm-up does not decide.
        for (form, asksWidth) in [("vorher", false), ("nachher", true), ("nachher-zuerst", true), ("vorher-danach", false)] {
            let ids = (0..<12).map { "li_peak_\(form)_\($0)_\(UUID().uuidString)" }
            let larges = ids.compactMap { client.largeCoverURL(forItemId: $0) }
            for url in larges { #expect(cache.testPlacePersistent(bytes, for: url)) }
            let asked = asksWidth ? ids.compactMap { client.coverURL(forItemId: $0) } : larges
            let baseline = Self.footprint()
            let peak = OSAllocatedUnfairLock(initialState: baseline)
            let sampler = Task.detached(priority: .high) {
                // detached because the sampler must run beside the decodes, off the main actor
                while !Task.isCancelled {
                    let now = Self.footprint()
                    peak.withLock { $0 = max($0, now) }
                    try? await Task.sleep(for: .milliseconds(2))
                }
            }
            var shown = 0
            for url in asked where await cache.thumbnail(for: url, maxPixelSize: 400) != nil { shown += 1 }
            sampler.cancel()
            #expect(shown == 12, "\(form): only \(shown) of twelve cells found their cover offline")
            let delta = peak.withLock { $0 } - baseline
            results[form] = delta
            Logger.library.notice("COVERPEAK offline-grid form=\(form, privacy: .public) cells=12 peakOverBaseline=\(delta / 1_048_576) MB")
            print("COVERPEAK offline-grid form=\(form) cells=\(shown) peakOverBaseline=\(Double(delta) / 1_048_576) MB")
            for url in larges { cache.testRemovePersistent(named: cache.testKey(for: url)) }
        }
        #expect(results.count == 4, "the measure ran")
    }
}
#endif
