// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A Jamendo track named by a shared link: asked for once by its id, live,
/// only while the source is on, and only when no row showed it this session.
@MainActor
struct JamendoTrackByIdTests {
    static let track = JamendoTrack(id: "1848357", name: "Abendlicht", artist_name: "Die Kapelle",
                                    image: "https://usercontent.jamendo.com/?type=album&id=1&trackid=1848357",
                                    audio: "https://prod-1.storage.jamendo.com/?trackid=1848357&format=mp32",
                                    shareurl: "https://www.jamendo.com/track/1848357", duration: 200)

    /// What the provider asked Jamendo for.
    final class Asked {
        var ids: [String] = []
    }

    /// A provider over its own folder, with a record of what was asked.
    private func makeProvider(allowed: Bool, answer: JamendoTrack?) throws -> (FreeCatalogProvider, () -> [String], URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jamendo-by-id-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let provider = FreeCatalogProvider(ablage: Ablage(directory: directory))
        let asked = Asked()
        provider.fetchJamendoTrack = { id in asked.ids.append(id); return answer }
        provider.jamendoAllowed = { allowed }
        return (provider, { asked.ids }, directory)
    }

    @Test("Die Adresse eines Titels nach Kennung: dieselbe Form wie die Reihe, nur Ziffern")
    func theAddressOfOneTrack() throws {
        let url = try #require(JamendoClient.trackURL(id: "1848357", clientId: "key"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let values = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        #expect(url.host == "api.jamendo.com" && url.path(percentEncoded: true) == "/v3.0/tracks/")
        #expect(values["id"] == "1848357" && values["limit"] == "1" && values["client_id"] == "key")
        #expect(values["audioformat"] == "mp32" && values["imagesize"] == String(FreeCatalog.jamendoCoverSize))
        for id in ["", "12a", "1&id=2", "-1", "１２"] {
            #expect(JamendoClient.trackURL(id: id, clientId: "key") == nil, "\(id)")
        }
    }

    @Test("Ein unbekannter Titel von Jamendo wird einmal nach Kennung gefragt, solange die Quelle an ist")
    func anUnknownTrackIsAskedForOnce() async throws {
        let (provider, asked, directory) = try makeProvider(allowed: true, answer: Self.track)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(provider.jamendoTrack(forId: "jam:1848357") == nil, "the precondition: no row showed the track")
        let detail = try await provider.fetchItemDetail(itemId: "jam:1848357")
        #expect(asked() == ["1848357"])
        #expect(detail.media.tracks?.first?.contentUrl == Self.track.audio)
        #expect(provider.sourceURL(forItemId: "jam:1848357")?.absoluteString == Self.track.shareurl,
                "the backlink to the track's page on Jamendo is missing")
        // Known now: the next detail asks nothing.
        _ = try await provider.fetchItemDetail(itemId: "jam:1848357")
        #expect(asked() == ["1848357"], "a known track was asked for again")
    }

    @Test("Mit der Quelle aus wird nichts gefragt, und der Titel oeffnet nicht")
    func theSourceOffAsksNothing() async throws {
        let (provider, asked, directory) = try makeProvider(allowed: false, answer: Self.track)
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: (any Error).self) { _ = try await provider.fetchItemDetail(itemId: "jam:1848357") }
        #expect(asked().isEmpty, "the switched off source was asked")
    }

    @Test("Ein Titel, den Jamendo nicht kennt oder unter anderer Kennung gibt, oeffnet nicht")
    func anUnknownOrOtherTrackDoesNotOpen() async throws {
        let (none, askedNone, first) = try makeProvider(allowed: true, answer: nil)
        defer { try? FileManager.default.removeItem(at: first) }
        await #expect(throws: (any Error).self) { _ = try await none.fetchItemDetail(itemId: "jam:1848357") }
        #expect(askedNone() == ["1848357"], "the precondition: Jamendo was asked")

        let other = JamendoTrack(id: "999", name: "Andere", artist_name: nil, image: nil,
                                 audio: "https://prod-1.storage.jamendo.com/?trackid=999", shareurl: nil, duration: 1)
        let (wrong, _, second) = try makeProvider(allowed: true, answer: other)
        defer { try? FileManager.default.removeItem(at: second) }
        await #expect(throws: (any Error).self) { _ = try await wrong.fetchItemDetail(itemId: "jam:1848357") }
    }
}
#endif
