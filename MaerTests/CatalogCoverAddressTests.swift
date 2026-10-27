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
            .contains("hiresCover ?? router.largeCoverURL(entry.id)"))
        #expect(try read("Sources/Views/PlayerScreen.swift")
            .contains("coverURL: router.largeCoverURL(item.id),"))
        #expect(try read("Sources/ViewModels/PlayerViewModel+NowPlaying.swift")
            .contains("songCoverURL ?? item.flatMap { provider.largeCoverURL(forItemId: $0.id) }"))
        #expect(try read("Sources/Providers/AudioProvider.swift")
            .contains("CoverAddressHistory.large(coverURL(forItemId: itemId))"), "the default asks the larger form")
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

    private static func file(_ name: String, source: String, format: String, bytes: Int) -> ArchiveFile {
        ArchiveFile(name: name, length: nil, title: nil, format: format, source: source, size: String(bytes))
    }

    @Test("archive.org: das groesste Original-Bild unter der Grenze, sonst der Dienst")
    func archiveTakesTheLargestOriginalPicture() throws {
        let files = [
            Self.file("cover small.jpg", source: "original", format: "JPEG", bytes: 80_000),
            Self.file("cover.png", source: "original", format: "PNG", bytes: 250_000),
            Self.file("scan.jpg", source: "original", format: "JPEG", bytes: FreeCatalog.archiveOriginalCoverCap + 1),
            Self.file("cover_thumb.jpg", source: "derivative", format: "JPEG", bytes: 300_000),
            Self.file("a.mp3", source: "original", format: "VBR MP3", bytes: 400_000),
        ]
        #expect(FreeCatalog.archiveOriginalCover(identifier: "rel", files: files)?.absoluteString
                == "https://archive.org/download/rel/cover.png")
        let onlySmall = [Self.file("cover small.jpg", source: "original", format: "JPEG", bytes: 80_000)]
        #expect(FreeCatalog.archiveOriginalCover(identifier: "rel", files: onlySmall)?.absoluteString
                == "https://archive.org/download/rel/cover%20small.jpg")
        #expect(FreeCatalog.archiveOriginalCover(identifier: "rel", files: [files[2], files[3], files[4]]) == nil,
                "a picture past the cap, a derivative or a sound is no large cover")
        // Measured on Vkrsnl038: the back is larger than the front; on
        // STQK011 the only front is a "Book Cover".
        let backLarger = [Self.file("Talk-To-Me-front-cover.jpg", source: "original", format: "JPEG", bytes: 118_639),
                          Self.file("Talk-to-me-back-cover.jpg", source: "original", format: "JPEG", bytes: 137_055)]
        #expect(FreeCatalog.archiveOriginalCover(identifier: "rel", files: backLarger)?.lastPathComponent
                == "Talk-To-Me-front-cover.jpg")
        let bookCover = [Self.file("STQK011_Cover.jpg", source: "original", format: "Book Cover", bytes: 148_170),
                         Self.file("STQK011_photo.jpg", source: "original", format: "JPEG", bytes: 300_000)]
        #expect(FreeCatalog.archiveOriginalCover(identifier: "rel", files: bookCover)?.lastPathComponent
                == "STQK011_Cover.jpg", "a named front comes before a larger other picture")
        #expect(FreeCatalog.archiveOriginalCover(identifier: "rel", files: [backLarger[1]]) == nil, "a back side alone")
        let original = try #require(URL(string: "https://archive.org/download/rel/cover.png"))
        #expect(CoverAddressHistory.formerAddress(of: original) == FreeCatalog.archiveCoverURL(identifier: "rel"))
        #expect(CoverAddressHistory.formerAddress(of: URL(string: "https://archive.org/download/rel/a.mp3")!) == nil)
    }

    @Test("die grosse Ansicht nimmt das Original, sobald die Dateiliste gelesen ist; das Raster bleibt beim Dienst")
    func theLargeViewTakesTheOriginalOnceTheFilesWereRead() async throws {
        let album = "lva:cover-witness-\(UUID().uuidString)"
        let identifier = try #require(FreeCatalog.archiveIdentifier(of: album))
        let provider = FreeCatalogProvider.shared
        let service = FreeCatalog.archiveCoverURL(identifier: identifier)
        #expect(provider.largeCoverURL(forItemId: album) == service, "the precondition: no files read yet")
        let json = """
            {"files": [{"name": "a.mp3", "length": "60", "format": "VBR MP3", "source": "original", "size": "900000"},
                       {"name": "front.jpg", "format": "JPEG", "source": "original", "size": "120000"}],
             "metadata": {"title": "Witness"}}
            """
        let meta = try ArchiveDecoder.decodeMetadata(Data(json.utf8))
        _ = await provider.releaseSongs(albumId: album) { _ in meta }
        #expect(provider.largeCoverURL(forItemId: album)?.absoluteString
                == "https://archive.org/download/\(identifier)/front.jpg")
        #expect(provider.coverURL(forItemId: album) == service, "the grid left the service")
    }

    @Test("nur die grossen Ansichten fragen largeCoverURL, nie das Raster", .needsTheSources)
    func onlyTheLargeViewsAskTheLargeCover() throws {
        // The four large views and the path that carries the question.
        let allowed: Set<String> = ["BookDetailScreen.swift", "PlayerScreen.swift", "PlayerViewModel+NowPlaying.swift",
                                    "MusicAlbumView.swift", "AudioProvider.swift", "AppSession.swift",
                                    "ItemRouterEnvironment.swift", "FreeCatalogProvider.swift"]
        var askers: Set<String> = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            if code.contains("largeCoverURL") { askers.insert(file.lastPathComponent) }
        }
        #expect(askers.subtracting(allowed).isEmpty, "a grid or row asks the large cover: \(askers.subtracting(allowed).sorted())")
        #expect(askers.isSuperset(of: ["BookDetailScreen.swift", "PlayerScreen.swift", "PlayerViewModel+NowPlaying.swift",
                                        "MusicAlbumView.swift"]),
                "the reader no longer sees the large views")
    }

    /// A grey strip several times wider than tall, the waveform the item
    /// image service answers for an item without a picture.
    private static func waveformStrip() throws -> Data {
        let width = 120, height = 20
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        return try #require(UIImage(cgImage: image).pngData())
    }

    @Test("ein Original wird nie als Platzhalter gemerkt, derselbe Streifen vom Dienst schon")
    func anOriginalIsNeverAPlaceholder() throws {
        let strip = try Self.waveformStrip()
        let service = FreeCatalog.archiveCoverURL(identifier: "rel")!
        #expect(ArchiveServicePlaceholder.isPlaceholder(data: strip, url: service), "the precondition: the strip is one")
        let original = URL(string: "https://archive.org/download/rel/front.png")!
        #expect(!ArchiveServicePlaceholder.isPlaceholder(data: strip, url: original),
                "an uploader's own picture was judged a placeholder and would be remembered as none")
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
