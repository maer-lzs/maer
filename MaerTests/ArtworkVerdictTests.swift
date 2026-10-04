// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
import UIKit
@testable import Maer

/// Die Bild-Tuer sagt, ob sie ein Bild hat, ob die Adresse keines nennt,
/// oder ob sie nichts gelernt hat. Nur das saubere Nein darf jemand als
/// „kein Bild“ merken; alles andere wird beim naechsten Mal wieder gefragt.
@Suite(.reachableNetwork)
struct ArtworkVerdictTests {
    private static func name(_ verdict: Artwork.Verdict) -> String {
        switch verdict {
        case .picture(let answer): return "picture:\(answer.pot)"
        case .absent: return "absent"
        case .unanswered: return "unanswered"
        }
    }

    private static func url(_ stand: BulkImportTests.Stand, _ name: String) -> URL {
        URL(string: "http://127.0.0.1:\(stand.port)/\(name)-\(UUID().uuidString).png")!
    }

    private static func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    /// A picture exactly `pixels` wide, so the old and the new cover can be
    /// told apart on disk.
    private static func png(pixels: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: pixels, height: pixels)
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// The persistent copy's width once the background write landed.
    private static func persistentWidth(_ url: URL, becomes width: Int) async throws -> Int? {
        for _ in 0..<40 {
            if persistentWidth(url) == width { return width }
            try await Task.sleep(for: .milliseconds(50))
        }
        return persistentWidth(url)
    }

    /// The persistent copy's pixel width, nil without one.
    private static func persistentWidth(_ url: URL) -> Int? {
        guard let data = ImageCache.shared.testPersistentBytes(url), let image = UIImage(data: data) else { return nil }
        return Int(image.size.width * image.scale)
    }

    /// The measured defect: pull-to-refresh on the music tab invalidated a
    /// downloaded album's cover, but the read paths found the persistent
    /// copy first, so the old cover stayed for good. Now the next display
    /// asks the server, and its picture replaces the persistent copy.
    @Test("nach einer Invalidierung zeigt ein geschuetztes Cover das Bild vom Server und steht danach geschuetzt als neues")
    func anInvalidatedKeptCoverIsReplacedByTheServer() async throws {
        let served = try await BulkImportTests.Stand.start(.answer(status: 200, body: Self.png(pixels: 24)))
        defer { served.stop() }
        let url = Self.url(served, "kept")
        #expect(ImageCache.shared.testPlacePersistent(Self.png(pixels: 8), for: url), "the precondition: an old kept cover")
        defer { ImageCache.shared.removePersistent(coverURL: url) }
        #expect(Self.name(await Artwork.verdict(for: url)) == "picture:full", "the precondition: the kept cover answers")
        Artwork.invalidate(url)
        #expect(Self.name(await Artwork.verdict(for: url)) == "picture:net", "the old kept cover answered after the invalidation")
        #expect(try await Self.persistentWidth(url, becomes: 24) == 24, "the server's picture did not replace the kept one")
        #expect(!ImageCache.shared.testIsRefreshing(url), "the address still waits for the network")
    }

    /// Offline, or with a server that fails, the kept cover is not lost: it
    /// stays on disk and on screen, and the next display asks again.
    @Test("scheitert das Laden nach einer Invalidierung, bleibt das alte geschuetzte Cover stehen und sichtbar")
    func aFailedLoadKeepsTheOldCover() async throws {
        let broken = try await BulkImportTests.Stand.start(.answer(status: 403, body: Data()))
        defer { broken.stop() }
        let url = Self.url(broken, "kept-broken")
        #expect(ImageCache.shared.testPlacePersistent(Self.png(pixels: 8), for: url), "the precondition: an old kept cover")
        defer { ImageCache.shared.removePersistent(coverURL: url) }
        Artwork.invalidate(url)
        #expect(Self.name(await Artwork.verdict(for: url)) == "picture:kept", "a failed load left the placeholder")
        #expect(await broken.settledCount(expected: 2) == 2, "the server was not asked")
        #expect(Self.persistentWidth(url) == 8, "the kept cover was lost")
        #expect(ImageCache.shared.testIsRefreshing(url), "the next display does not ask again")
    }

    @Test("Tuer: ein 404 ist absent, ein 403 und Bytes ohne Bild sind unanswered und werden noch einmal gefragt, ein Bild ist picture und liegt danach auf der Platte")
    func theVerdictNamesWhatWasLearned() async throws {
        let gone = try await BulkImportTests.Stand.start(.answer(status: 404, body: Data("{\"error\":\"none\"}".utf8)))
        defer { gone.stop() }
        #expect(Self.name(await Artwork.verdict(for: Self.url(gone, "gone"))) == "absent")
        #expect(await gone.settledCount(expected: 1) == 1, "an absence was asked twice")

        let refused = try await BulkImportTests.Stand.start(.answer(status: 403, body: Data()))
        defer { refused.stop() }
        #expect(Self.name(await Artwork.verdict(for: Self.url(refused, "refused"))) == "unanswered")
        #expect(await refused.settledCount(expected: 2) == 2, "a status that is no answer gets the second attempt")

        let garbage = try await BulkImportTests.Stand.start(.answer(status: 200, body: Data("{\"detail\":\"not a picture\"}".utf8)))
        defer { garbage.stop() }
        #expect(Self.name(await Artwork.verdict(for: Self.url(garbage, "garbage"))) == "unanswered")

        let served = try await BulkImportTests.Stand.start(.answer(status: 200, body: Self.png()))
        defer { served.stop() }
        let picture = Self.url(served, "picture")
        #expect(Self.name(await Artwork.verdict(for: picture)) == "picture:net")
        #expect(await Artwork.full(for: picture) != nil, "the picture did not reach the cache")
        #expect(Self.name(await Artwork.verdict(for: picture)) == "picture:full", "the second look asked the network again")
    }

    @Test("Tuer: eine Kachel, die waehrend ihrer Frist verschwindet, bekommt unanswered, kein Nein")
    func aTileThatLeftLearnsNothing() async throws {
        let served = try await BulkImportTests.Stand.start(.answer(status: 200, body: Self.png()))
        defer { served.stop() }
        let leaving = Task {
            await TileDwell.standing { Self.name(await Artwork.verdict(for: Self.url(served, "left"))) }
        }
        try await Task.sleep(for: .milliseconds(100))
        leaving.cancel()
        #expect(await leaving.value == "unanswered")
        #expect(await served.settledCount(expected: 0) == 0, "a tile that left was asked")
    }

    @Test("Zaun: die zwei Merker rufen verdict, nie image, und ihr unanswered-Zweig bucht nichts", .needsTheSources)
    func theRememberersReadTheVerdict() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Sources/Networking/CoverArtArchive.swift", "Sources/Networking/RadioArtworkService.swift"] {
            let text = SyncContractFenceTests.stripped(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8))
            #expect(!text.contains("Artwork.image("), "\(path) asks without the verdict")
            #expect(text.contains("Artwork.verdict("), "\(path) does not ask the door")
            let lines = text.split(separator: "\n")
                .map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
                .filter { $0.contains("case .unanswered") }
            #expect(!lines.isEmpty, "\(path) has no unanswered branch")
            for line in lines {
                #expect(line.contains("return nil") && !line.contains("missing"), "\(path) books on unanswered: \(line)")
            }
        }
    }
}
