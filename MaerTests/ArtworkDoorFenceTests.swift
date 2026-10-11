// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Pictures pass the one door `Artwork`. The homes are the door itself,
/// the cache behind it (`ImageCache`) and the byte probe (`ImageProbe`);
/// every other file asks the door. Counted per file, comment lines
/// excluded: `UIImage(data:` (decoding bytes), `lane: .cover` (the cover
/// lane of the HTTP door), `CGImageSource` and `import ImageIO` (the
/// downsampler). Measured the day the door was built (06.09.2026): eleven
/// files carried a marker; the stock is the count, both ways. The widget extension is its own target with
/// the app group as the hand-over place, outside `Sources` and outside
/// this fence by design. And `ImageCache.shared` is the door's own
/// business: only the door and the cache itself name it.
struct ArtworkDoorFenceTests {

    nonisolated static let markers = ["UIImage(data:", "lane: .cover", "CGImageSource", "import ImageIO"]

    /// The marker sites of a file outside comment lines.
    nonisolated static func markerSites(in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { sum, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { return sum }
            return sum + Self.markers.reduce(0) { $0 + line.components(separatedBy: $1).count - 1 }
        }
    }

    /// Lines naming `ImageCache.shared` outside comments.
    nonisolated static func cacheSites(in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//") && line.contains("ImageCache.shared")
        }.count
    }

    /// The homes and their stock on the day of the fence.
    // BESTAND OHNE EINZELGRUENDE: die drei Eintraege haben denselben Grund, sie SIND die
    // Heimaten der Tuer. Ein Satz je Zeile waere derselbe Satz dreimal.
    nonisolated static let stock: [String: Int] = [
        "ImageCache.swift": 20,
        "ImageProbe.swift": 5,
        "Artwork.swift": 3,
    ]

    @Test("Bildbytes werden nur hinter der Tuer dekodiert, der Bestand faellt nur")
    func markersLiveBehindTheDoor() throws {
        var counts: [String: Int] = [:]
        for file in ProjectFileIntegrityTests.sourceFiles() {
            counts[file.lastPathComponent, default: 0] += Self.markerSites(in: try String(contentsOf: file, encoding: .utf8))
        }
        let drift = StockDrift.findings(counts: counts, stock: Self.stock)
        #expect(drift.isEmpty, "picture markers outside the door, or a stock above the count: \(drift)")
        #expect(Self.markerSites(in: "let image = UIImage(data: bytes)") == 1)
        #expect(Self.markerSites(in: "try await HTTP.data(from: url, lane: .cover)") == 1)
        #expect(Self.markerSites(in: "import ImageIO\nlet source = CGImageSourceCreateWithData(data as CFData, nil)") == 2)
        #expect(Self.markerSites(in: "// UIImage(data:) is for the door") == 0)
        #expect(Self.markerSites(in: "let image = await Artwork.image(for: url)?.image") == 0)
    }

    @Test("ImageCache.shared kennen nur die Tuer und der Cache")
    func cacheIsTheDoorsBusiness() throws {
        var offenders: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let name = file.lastPathComponent
            guard name != "Artwork.swift", name != "ImageCache.swift" else { continue }
            let found = Self.cacheSites(in: try String(contentsOf: file, encoding: .utf8))
            if found > 0 { offenders.append("\(name): \(found)") }
        }
        #expect(offenders.isEmpty, "ImageCache.shared outside the door: \(offenders)")
        #expect(Self.cacheSites(in: "ImageCache.shared.set(image, for: url)") == 1)
        #expect(Self.cacheSites(in: "// ImageCache.shared was here") == 0)
    }

    @Test("Ein Server-Cover reist nie, ein oeffentliches darf")
    func serverCoversStayHome() {
        #expect(!SyncCarried.coverMayTravel("sub:al-42"))
        #expect(!SyncCarried.coverMayTravel("jf:0123456789abcdef"))
        #expect(!SyncCarried.coverMayTravel("f1a2b3c4-d5e6-7890-abcd-ef1234567890"))
        #expect(SyncCarried.coverMayTravel("\(FreeCatalog.librivoxPrefix)1234"))
        #expect(SyncCarried.coverMayTravel("radio:station-1"))
        #expect(SyncCarried.coverMayTravel("rss:feed-hash:episode-guid"))
        let server = SyncCarried.snapshot(forId: "sub:al-42", known: nil, coverURL: URL(string: "https://music.example/rest/getCoverArt?u=me&t=token"))
        #expect(server == nil)
    }
}
#endif
