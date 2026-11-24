// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
import UIKit
@testable import Maer

/// The drawn cover of a Musopen recording is a cover like any other: it has
/// an address, the door of the covers draws what the address names, and so
/// the mini player, rows, lists and their collages, the lock screen,
/// CarPlay and the widget show it where they show any cover.
@MainActor
struct DrawnCoverTests {
    @Test("the address carries title and composer and reads back; any other address is not drawn")
    func addressReadsBack() throws {
        let url = DrawnCover.url(title: "La Traviata: Prelude", composer: "Giuseppe Verdi")
        let parts = try #require(DrawnCover.parts(of: url))
        #expect(parts.title == "La Traviata: Prelude" && parts.composer == "Giuseppe Verdi")
        #expect(DrawnCover.parts(of: DrawnCover.url(title: "Étude & Fugue?", composer: nil))?.title == "Étude & Fugue?")
        #expect(DrawnCover.parts(of: URL(string: "https://upload.wikimedia.org/x.jpg")!) == nil)
    }

    @Test("a recording's cover address is its drawn address, from the title and the artist the provider knows")
    func providerNamesTheDrawnAddress() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("drawn-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = FreeCatalogProvider(ablage: Ablage(directory: directory))
        let recording = MusopenCatalog.Recording(pageId: 424242, title: "File:Verdi - La Traviata - Prelude.ogg",
                                                 artistHTML: "Giuseppe Verdi", duration: 200,
                                                 licence: .publicDomain, audioURL: URL(string: "https://upload.wikimedia.org/a.ogg")!,
                                                 pageURL: nil)
        let item = try #require(provider.remember(recording: recording))
        let url = try #require(provider.coverURL(forItemId: item.id))
        #expect(DrawnCover.parts(of: url)?.composer == "Giuseppe Verdi", "\(url)")
        #expect(provider.largeCoverURL(forItemId: item.id) == url)
    }

    @Test("the door draws the address into a square picture of the large cover's size")
    func theDoorDraws() async throws {
        let url = DrawnCover.url(title: "Symphony No. 5", composer: "Ludwig van Beethoven")
        let (data, http) = try await Artwork.bytes(from: url)
        #expect(http == nil)
        let image = try #require(UIImage(data: data))
        #expect(image.size.width == DrawnCoverRenderer.side && image.size.height == DrawnCoverRenderer.side)
    }
}
#endif
