// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import UIKit
@testable import Maer

/// A fetched cover is held and stored at display size, never as its
/// original: a 3000 px cover is 36 MB decoded. A cell gets a picture at the
/// size it asked for, and memory pressure releases the full covers.
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

    /// A cell that asked for a thumbnail gets one from a fresh fetch, not
    /// the cover at display size.
    @Test("ein frisch geladenes Cover kommt in eine Zelle in der Groesse, die sie anfragt")
    func aFreshCoverReachesACellAtItsSize() async throws {
        let (display, _) = try #require(await ImageCache.displaySized(png(3000), maxPixelSize: 2000))
        let thumb = await ImageCache.reduced(display, maxPixelSize: 400)
        #expect(pixels(thumb) == 400, "the cell's size: \(pixels(thumb))")
        let small = try #require(UIImage(data: png(300)))
        #expect(await ImageCache.reduced(small, maxPixelSize: 400) === small, "a picture already as small stays")
    }

    @Test("die Bild-Tuer gibt einer Vorschau-Zelle nach dem Netz eine Vorschau", .needsTheSources)
    func theDoorSizesTheNetworkAnswer() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/Artwork.swift"), encoding: .utf8))
        #expect(code.components(separatedBy: "Answer(image: await sized(image, maxPixel), pot: \"net").count - 1 == 2,
                "both network answers are sized for the cell")
        #expect(!code.contains("Answer(image: image, pot: \"net"), "a network answer goes to the cell unsized")
    }

    /// Memory pressure releases the full covers and leaves the thumbnails,
    /// so the cells on screen stay warm. The system's own notification, as
    /// the device sends it.
    @Test("Speicherdruck gibt die grossen Cover frei, die Vorschauen bleiben warm")
    func memoryPressureReleasesTheFullCovers() async throws {
        let cache = ImageCache.shared
        let url = URL(string: "https://covers.example.invalid/pressure-\(UUID().uuidString).png")!
        let (shown, kept) = try #require(await ImageCache.displaySized(png(600), maxPixelSize: cache.displayPixelSize))
        cache.set(shown, data: kept, for: url, startedAt: cache.invalidationCount(for: url))
        // A thumbnail is read from disk, where the write of `set` lands a
        // moment later.
        for _ in 0..<40 where cache.cachedThumbnail(for: url) == nil {
            _ = await cache.thumbnail(for: url)
            if cache.cachedThumbnail(for: url) == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(cache.holdsFullCover(for: url), "the precondition: the cover stands in memory")
        #expect(cache.cachedThumbnail(for: url) != nil, "the precondition: the thumbnail is warm")
        let releases = cache.fullCoverReleases
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        #expect(cache.fullCoverReleases == releases + 1, "the pressure reached the cache")
        #expect(!cache.holdsFullCover(for: url), "the full cover is released")
        #expect(cache.cachedThumbnail(for: url) != nil, "the pressure took the thumbnail too")
    }

    /// No path in the network layer stores a fetched cover as it came: every
    /// caller of `set` hands it the picture and the bytes `displaySized`
    /// gave, whatever their names.
    @Test("kein Weg im Netz-Ordner legt ein frisch geladenes Cover unverkleinert ab", .needsTheSources)
    func noPathStoresTheOriginal() throws {
        // Not `\b`: by Unicode's word rules `tiers.set` is one word.
        let call = try Regex(#"(?:^|\W)set\((\w+), data: (\w+), for:"#)
        var calls = 0
        var offenders: [String] = []
        for url in SourceTree.files(under: SourceTree.root.appendingPathComponent("Sources/Networking")) where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                Issue.record("unreadable: \(SourceTree.relativePath(of: url))")
                continue
            }
            let code = SyncContractFenceTests.stripped(text)
            for match in code.matches(of: call) {
                calls += 1
                let image = match.output[1].substring ?? "", data = match.output[2].substring ?? ""
                let reduced = try Regex(#"let \(\#(image), \#(data)\) = await (Self|ImageCache)\.displaySized\("#)
                if !code.contains(reduced) { offenders.append("\(url.lastPathComponent): set(\(image), data: \(data)") }
            }
        }
        #expect(calls >= 3, "the fence found no caller of set, so it measures nothing: \(calls)")
        #expect(offenders == [], "stores the original: \(offenders)")
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
