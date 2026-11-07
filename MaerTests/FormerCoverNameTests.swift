// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import UIKit
@testable import Maer

/// An Audiobookshelf cover is asked unscaled (`raw`), so its file name
/// changed. A downloaded book keeps its old cover under the former name:
/// offline it shows that one until the unscaled one has come, the network
/// gate still asks for the new one, and the sweep keeps the old file while
/// today's name has no kept cover.
@MainActor
@Suite(.serialized)
struct FormerCoverNameTests {
    /// A square of `side` pixels (scale 1, so the pixel count tells the files apart).
    private func png(_ side: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.pngData { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    private func address(_ tag: String, raw: Bool) -> URL {
        URL(string: "https://abs.example.lan/api/items/li_\(tag)/cover?\(raw ? "raw=1&" : "")token=tok")!
    }

    private func pixels(_ image: UIImage?) -> CGFloat? {
        image.map { $0.size.width * $0.scale }
    }

    @Test("die frueheren Namen eines Audiobookshelf-Covers: der Name nach Adresse, dann der Name der Adresse ohne raw")
    func theFormerNameIsTheNameWithoutRaw() {
        let tag = UUID().uuidString
        let cache = ImageCache.shared
        #expect(cache.formerNames(for: address(tag, raw: true))
                == [ImageCache.addressName(for: address(tag, raw: true)), ImageCache.addressName(for: address(tag, raw: false))])
        #expect(cache.formerNames(for: address(tag, raw: false)) == [ImageCache.addressName(for: address(tag, raw: false))])
        #expect(cache.formerNames(for: URL(string: "https://nd.example.lan/rest/getCoverArt?id=al-1&raw=1")!).isEmpty)
    }

    @Test("offline: alte Datei da, neue nicht, das alte Bild kommt; das Netz-Tor sieht es nicht")
    func theOldCoverAnswersWhenNoNewOneStands() async throws {
        let tag = UUID().uuidString
        let url = address(tag, raw: true)
        let cache = ImageCache.shared
        let former = try #require(cache.formerNames(for: url).first)
        #expect(cache.testPlacePersistent(png(64), named: former), "the precondition: the old cover is kept")
        defer { cache.testRemovePersistent(named: former) }
        #expect(!cache.testIsPersistent(url), "the precondition: nothing under today's name")
        #expect(pixels(await cache.image(for: url)) == 64)
        #expect(await cache.thumbnail(for: url) != nil)
        #expect(await cache.image(for: url, allowKept: false) == nil, "the network gate took the old cover")
        #expect(await cache.thumbnail(for: url, maxPixelSize: 400, allowKept: false) == nil,
                "the network gate took the old cover")
    }

    @Test("beide Dateien da: das neue Bild kommt")
    func theNewCoverWinsOverTheOld() async throws {
        let tag = UUID().uuidString
        let url = address(tag, raw: true)
        let cache = ImageCache.shared
        let former = try #require(cache.formerNames(for: url).first)
        #expect(cache.testPlacePersistent(png(64), named: former))
        #expect(cache.testPlacePersistent(png(32), for: url))
        defer {
            cache.testRemovePersistent(named: former)
            cache.testRemovePersistent(named: cache.testKey(for: url))
        }
        #expect(pixels(await cache.image(for: url)) == 32)
    }

    @Test("der Fegelauf behaelt den frueheren Namen, bis der heutige geschuetzt steht")
    func theSweepKeepsTheFormerNameUntilTodaysIsKept() {
        let formers = ["today": ["former"]]
        #expect(ImageCache.keptFormerNames(formers, persistent: ["former"]) == ["former"])
        #expect(ImageCache.keptFormerNames(formers, persistent: ["former", "today"]).isEmpty)
        let moves = ImageCache.tierMoves(persistent: ["former"], cache: [],
                                         active: Set(["today"]).union(ImageCache.keptFormerNames(formers, persistent: ["former"])),
                                         knowsAll: true)
        #expect(moves.isEmpty, "the sweep moved the old cover of a download down")
    }

    @Test("der Fegelauf zaehlt die frueheren Namen zu den aktiven", .needsTheSources)
    func theSweepCountsTheFormerNames() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/ImageCache.swift"), encoding: .utf8))
        let start = try #require(code.range(of: "func performMaintenance(")).upperBound
        let rest = code[start...]
        let sweep = String(rest[..<(rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex)])
        #expect(sweep.contains("activeNames.union(Self.keptFormerNames(formers, persistent: persistentNames))"))
        #expect(sweep.contains("active: active,"), "the tier moves ignore the former names")
    }
}
#endif
