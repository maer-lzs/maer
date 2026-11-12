// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import UIKit
@testable import Maer

/// The picture of the share sheet's preview: the cover from the app's
/// store, never from the network; without one, the app's icon.
@MainActor
@Suite(.serialized)
struct SharedLinkPreviewTests {
    @Test("Die Vorschau nimmt das Cover aus dem Speicher, sonst das Symbol der App")
    func thePreviewTakesTheStoredCover() async throws {
        #expect(SharedLinkPreview.appIcon != nil, "the precondition: the app's icon is found in its bundle")
        let cover = try #require(URL(string: "https://covers.example/show.jpg"))
        var asked: [URL] = []
        _ = await SharedLinkPreview.image(cover: cover, stored: { url in
            asked.append(url)
            return UIImage(systemName: "star")
        })
        #expect(asked == [cover], "the store was not asked for the cover: \(asked)")
        asked = []
        _ = await SharedLinkPreview.image(cover: nil, stored: { url in
            asked.append(url)
            return nil
        })
        #expect(asked.isEmpty, "without a cover nothing is asked")
    }

    @Test("Die Vorschau fragt kein Netz: ein Cover, das nicht im Speicher liegt, erreicht seinen Host nicht")
    func thePreviewAsksNoNetwork() async throws {
        let server = try await ABSLoopback.start(login: .refuse, libraries: .refuse)
        defer { server.stop() }
        let cover = try #require(URL(string: "\(server.address)/cover-\(UUID().uuidString).jpg"))
        // The real way of the pages: the app's store.
        _ = await SharedLinkPreview.image(cover: cover)
        // The instrument sees a request: one through the app's door arrives.
        _ = try? await HTTP.data(for: URLRequest(url: try #require(URL(string: "\(server.address)/probe"))),
                                lane: .api, retry: false)
        let paths = server.requests.map(\.path)
        #expect(paths.contains("/probe"), "the precondition: the host records what reaches it \(server.diagnosis)")
        #expect(!paths.contains { $0.hasPrefix("/cover-") }, "the preview asked the network: \(paths)")
    }

    @Test("Zaun: die Vorschau liest nur ueber Artwork.thumbnail, keinen Weg ins Netz", .needsTheSources)
    func thePreviewReadsOnlyTheStore() throws {
        let root = SourceTree.root.appendingPathComponent("Sources/Views/SharedLinkButton.swift")
        let code = SyncContractFenceTests.stripped(try String(contentsOf: root, encoding: .utf8))
        #expect(code.contains("Artwork.thumbnail(for:"), "the preview does not read the store")
        let network = ["Artwork.image(", "Artwork.loaded(", "Artwork.preload(", "Artwork.verdict(", "Artwork.file(",
                       "HTTP.", "URLSession", "AsyncImage", "Data(contentsOf"]
        let found = network.filter { code.contains($0) }
        #expect(found.isEmpty, "the preview reaches past the store: \(found)")
    }
}
#endif
