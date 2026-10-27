// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
import UIKit
@testable import Maer

/// A catalogue cover keeps its small form in the grid and asks its largest
/// keyless form in the large views; where that names no picture, the image
/// door falls back to the smaller address, and a cover kept under the
/// smaller name stays readable offline.
@MainActor
@Suite(.serialized)
struct CatalogCoverAddressTests {
    @Test("das Raster behaelt die mittlere Form, die grossen Ansichten fragen den Scan")
    func theGridKeepsTheMediumFormTheLargeViewsTheScan() throws {
        let medium = try #require(FreeCatalog.gutenbergCoverURL(number: "1342"))
        #expect(medium.absoluteString == "https://www.gutenberg.org/cache/epub/1342/pg1342.cover.medium.jpg",
                "the grid asks the scan, more than three times the bytes")
        let scan = try #require(CoverAddressHistory.large(medium))
        #expect(scan.absoluteString == "https://www.gutenberg.org/cache/epub/1342/images/cover.jpg")
        #expect(CoverAddressHistory.formerAddress(of: scan) == medium)
        #expect(CoverAddressHistory.formerAddress(of: medium) == nil, "the medium form has no earlier one")
        #expect(CoverAddressHistory.largerAddress(of: scan) == nil, "the scan has no larger one")
        #expect(FreeCatalog.gutenbergScanURL(number: "13a") == nil)
        // An address without a larger form stays as it is, nil stays nil.
        let archive = URL(string: "https://archive.org/services/img/x")!
        #expect(CoverAddressHistory.large(archive) == archive)
        #expect(CoverAddressHistory.large(nil) == nil)
        #expect(CoverAddressHistory.formerAddress(of: archive) == nil)
    }

    @Test("die grossen Ansichten fragen die grosse Form", .needsTheSources)
    func theLargeViewsAskTheLargeForm() throws {
        func read(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(
                contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        #expect(try read("Sources/Views/BookDetailScreen.swift")
            .contains("hiresCover ?? CoverAddressHistory.large(router.coverURL(entry.id))"))
        #expect(try read("Sources/Views/PlayerScreen.swift")
            .contains("coverURL: CoverAddressHistory.large(router.coverURL(item.id)),"))
        #expect(try read("Sources/ViewModels/PlayerViewModel+NowPlaying.swift")
            .contains("CoverAddressHistory.large(item.flatMap { provider.coverURL(forItemId: $0.id) })"))
    }

    @Test("Jamendo fragt 600 Pixel ueberall, 300 ist der fruehere Name", .needsTheSources)
    func jamendoAsksTheLargerSizeEverywhere() throws {
        let large = try #require(URL(string: "https://usercontent.jamendo.com?type=album&id=7&width=600&trackid=9"))
        #expect(CoverAddressHistory.formerAddress(of: large)?.absoluteString
                == "https://usercontent.jamendo.com?type=album&id=7&width=300&trackid=9")
        #expect(CoverAddressHistory.large(large) == large, "the grid already holds the larger one")
        let small = try #require(URL(string: "https://usercontent.jamendo.com?type=album&id=7&width=300&trackid=9"))
        #expect(CoverAddressHistory.formerAddress(of: small) == nil)
        #expect(ImageCache.shared.formerName(for: large) == ImageCache.shared.testKey(for: small))
        let clients = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/FreeCatalogClients.swift"), encoding: .utf8))
        #expect(clients.contains("URLQueryItem(name: \"imagesize\", value: String(FreeCatalog.jamendoCoverSize))"))
        #expect(JamendoClient.popularRule.hasSuffix("|\(FreeCatalog.jamendoCoverSize)"),
                "a stored answer with smaller covers is still found")
    }

    @Test("ein Cover unter der kleinen Adresse bleibt offline lesbar")
    func theEarlierNameIsAReadCandidate() throws {
        let medium = try #require(FreeCatalog.gutenbergCoverURL(number: "1342"))
        let scan = try #require(CoverAddressHistory.large(medium))
        #expect(ImageCache.shared.formerName(for: scan) == ImageCache.shared.testKey(for: medium))
    }

    private static func png(pixels: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: pixels, height: pixels)
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.green.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    @Test("nennt die grosse Adresse kein Bild, kommt die fruehere und steht unter der grossen")
    func anAbsentScanFallsBackToTheEarlierAddress() async throws {
        let missing = try await BulkImportTests.Stand.start(.answer(status: 404, body: Data()))
        defer { missing.stop() }
        let earlier = try await BulkImportTests.Stand.start(.answer(status: 200, body: Self.png(pixels: 12)))
        defer { earlier.stop() }
        let scan = URL(string: "http://127.0.0.1:\(missing.port)/scan-\(UUID().uuidString).jpg")!
        let medium = URL(string: "http://127.0.0.1:\(earlier.port)/medium-\(UUID().uuidString).jpg")!
        Artwork.testFormerAddress = { $0 == scan ? medium : nil }
        defer {
            Artwork.testFormerAddress = nil
            ImageCache.shared.testRemovePersistent(named: ImageCache.shared.testKey(for: scan))
        }
        guard case .picture = await Artwork.verdict(for: scan) else {
            Issue.record("the absent scan left no picture")
            return
        }
        #expect(await earlier.settledCount(expected: 1) == 1, "the earlier address was not asked")
        #expect(await ImageCache.shared.image(for: scan) != nil, "the picture is not kept under the scan's name")

        // Without an earlier address an absence stays an absence.
        let alone = URL(string: "http://127.0.0.1:\(missing.port)/alone-\(UUID().uuidString).jpg")!
        guard case .absent = await Artwork.verdict(for: alone) else {
            Issue.record("an address without an earlier one is no absence")
            return
        }
    }
}
#endif
