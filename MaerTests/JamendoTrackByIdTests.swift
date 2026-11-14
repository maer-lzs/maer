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

    @Test("The address of a title by id: the same form as the row, digits only")
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

    @Test("An unknown Jamendo title is asked for once by id, as long as the source is on")
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

    @Test("The track of a Jamendo title carries its name, never a part of the stream address")
    func theTrackOfAJamendoTitleCarriesItsName() async throws {
        let (provider, _, directory) = try makeProvider(allowed: true, answer: Self.track)
        defer { try? FileManager.default.removeItem(at: directory) }
        let detail = try await provider.fetchItemDetail(itemId: "jam:1848357")
        let track = try #require(detail.media.tracks?.first)
        #expect(track.contentUrl.contains("?"), "the precondition: the stream address carries a query")
        #expect(track.metadata?.title == "Abendlicht", "the track has no name of its own: \(String(describing: track.metadata?.title))")
    }

    @Test("The row title of a Jamendo title is its name, otherwise the title of the page; other titles as before")
    func theRowTitleOfAJamendoTrackIsItsName() {
        let stream = "https://prod-1.storage.jamendo.com/?trackid=1848357&format=mp32&from=AAAA==|BBBB=="
        for series in [true, false] {
            let named = FreeCatalog.trackRowTitle(itemId: "jam:1848357", stated: "Abendlicht", contentUrl: stream,
                                                  series: series, fallback: "Seite")
            #expect(named.title == "Abendlicht" && named.airDate == nil, "\(named)")
            let unnamed = FreeCatalog.trackRowTitle(itemId: "jam:1848357", stated: " ", contentUrl: stream,
                                                    series: series, fallback: "Seite")
            #expect(unnamed.title == "Seite", "\(unnamed)")
        }
        // The precondition: the address alone would show its query.
        #expect(FreeCatalog.trackDisplayTitle(contentUrl: stream).contains("from="))
        // Every other title as before: the stated name on an album, the file
        // name's episode in a series.
        let file = "https://archive.org/download/x/Folge_12_Der_Fall.mp3"
        #expect(FreeCatalog.trackRowTitle(itemId: "lva:x", stated: "Benannt", contentUrl: file, series: false, fallback: "S").title
                == "Benannt")
        #expect(FreeCatalog.trackRowTitle(itemId: "lva:x", stated: nil, contentUrl: file, series: false, fallback: "S").title
                == FreeCatalog.trackDisplayTitle(contentUrl: file))
        #expect(FreeCatalog.trackRowTitle(itemId: "lva:x", stated: "Benannt", contentUrl: file, series: true, fallback: "S").title
                == FreeCatalog.otrEpisode(fromFileName: FreeCatalog.trackDisplayTitle(contentUrl: file)).title)
    }

    @Test("Fence: the name from the address is asked only in FreeCatalog, and never for a Jamendo title", .needsTheSources)
    func theAddressNameIsNeverAskedForAJamendoTrack() throws {
        var callers: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            if code.contains("trackDisplayTitle(") { callers.append(file.lastPathComponent) }
        }
        #expect(callers == ["FreeCatalog.swift"], "the name from the address is asked elsewhere: \(callers)")
        let catalog = SourceTree.root.appendingPathComponent("Sources/Models/FreeCatalog.swift")
        let code = SyncContractFenceTests.stripped(try String(contentsOf: catalog, encoding: .utf8))
        let rule = try #require(code.range(of: "static func trackRowTitle("), "the precondition: the rule stands")
        let body = code[rule.upperBound...]
        let jamendo = try #require(body.range(of: "itemId.hasPrefix(jamendoPrefix)"))
        let address = try #require(body.range(of: "trackDisplayTitle(contentUrl: contentUrl)"))
        #expect(jamendo.lowerBound < address.lowerBound, "the rule reads the address before it asks for Jamendo")
    }

    @Test("With the source off nothing is asked, and the title does not open")
    func theSourceOffAsksNothing() async throws {
        let (provider, asked, directory) = try makeProvider(allowed: false, answer: Self.track)
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: (any Error).self) { _ = try await provider.fetchItemDetail(itemId: "jam:1848357") }
        #expect(asked().isEmpty, "the switched off source was asked")
    }

    @Test("A title that Jamendo does not know or gives under another id does not open")
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
