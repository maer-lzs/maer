// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import UIKit
@testable import Maer

/// A fetched cover is held at display size, never as its original (Platz 5).
/// Before, a fresh cover went into memory in full: a 3000 px cover is 36 MB
/// decoded, and a cell that fetched it was handed that bitmap.
@MainActor
@Suite(.serialized)
struct CoverMemoryTests {
    private func png(_ side: Int) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }()).pngData { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    private func pixels(_ image: UIImage) -> Int {
        Int(max(image.size.width, image.size.height) * image.scale)
    }

    @Test("ein grosses Cover wird vor dem Halten auf Anzeigegroesse gebracht, ein kleines bleibt")
    func aLargeCoverIsReducedBeforeItIsHeld() async throws {
        let limit = ImageCache.shared.displayPixelSize
        let (large, largeBytes) = try #require(await ImageCache.displaySized(png(3000), maxPixelSize: limit))
        #expect(CGFloat(pixels(large)) <= limit, "held at display size: \(pixels(large)) for \(limit)")
        let stored = try #require(UIImage(data: largeBytes))
        #expect(CGFloat(pixels(stored)) <= limit, "the bytes kept are the reduced cover")
        let small = png(300)
        let (kept, keptBytes) = try #require(await ImageCache.displaySized(small, maxPixelSize: limit))
        #expect(pixels(kept) == 300 && keptBytes == small, "a cover under the size stays as it came")
    }

    /// The one network path reduces before it stores and hands on: the
    /// picture `set` gets and the fetch returns is the reduced one.
    @Test("der Netzweg legt nur die verkleinerte Fassung ab und gibt nur sie weiter", .needsTheSources)
    func theNetworkPathHoldsTheReducedCover() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/Artwork.swift"), encoding: .utf8))
        let fetch = try #require(code.range(of: "private static func fetch("), "the network path")
        let body = code[fetch.lowerBound...]
        #expect(body.contains("ImageCache.displaySized(data"), "the fetch reduces the bytes")
        #expect(body.contains("tiers.set(shown, data: kept"), "it stores the reduced cover")
        #expect(body.contains("return .picture(shown)"), "it hands on the reduced cover")
        #expect(!body.contains("tiers.set(image"), "the original is stored")
    }
}
#endif
