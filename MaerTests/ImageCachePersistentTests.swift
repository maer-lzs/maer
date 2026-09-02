// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import UIKit
@testable import Maer

/// The persistent cover of a downloaded item must be found by the same
/// read paths that serve every tile. It once was not: the persistent
/// name came from the item id without host, the read paths looked for
/// the URL key with host, and the offline cover of a downloaded book
/// did not exist for seven weeks without any test noticing.
@MainActor
struct ImageCachePersistentTests {
    private func png(_ side: Int) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.pngData { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    /// An ABS-shaped address with a token as long as a real one, so the
    /// case also covers the digest path of the key.
    private func coverURL(_ tag: String) -> URL {
        URL(string: "https://abs.example.lan/api/items/li_\(tag)/cover?token="
            + String(repeating: "x", count: 220))!
    }

    @Test("ein persistiertes Cover wird von Vorschau- und Vollbild-Pfad gefunden")
    func persistedCoverIsFoundByTheReadPaths() async {
        let url = coverURL(UUID().uuidString)
        await ImageCache.shared.makePersistent(coverURL: url, data: png(64))
        defer { ImageCache.shared.removePersistent(coverURL: url) }
        #expect(await ImageCache.shared.thumbnail(for: url) != nil)
        #expect(await ImageCache.shared.image(for: url) != nil)
    }

    /// Rot-Probe: ein anderer Name wird NICHT gefunden. Der Vorschau-Pfad
    /// liest nur die Platte, also ist nil hier ein echtes Fehlen.
    @Test("ein anderer Name wird nicht gefunden")
    func aDifferentNameIsNotFound() async {
        let url = coverURL(UUID().uuidString)
        await ImageCache.shared.makePersistent(coverURL: url, data: png(64))
        defer { ImageCache.shared.removePersistent(coverURL: url) }
        let other = coverURL(UUID().uuidString)
        #expect(await ImageCache.shared.thumbnail(for: other) == nil)
    }

    /// Nach dem Entfernen des Downloads bleibt das Bild lesbar: die Kopie
    /// wandert in den Cache statt zu verschwinden.
    @Test("nach dem Entfernen bleibt das Bild aus dem Cache lesbar")
    func unpersistedCoverStaysReadableFromTheCache() async {
        let url = coverURL(UUID().uuidString)
        await ImageCache.shared.makePersistent(coverURL: url, data: png(64))
        ImageCache.shared.removePersistent(coverURL: url)
        #expect(await ImageCache.shared.thumbnail(for: url) != nil)
    }
}
#endif
