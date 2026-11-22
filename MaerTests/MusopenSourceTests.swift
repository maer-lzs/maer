// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The Musopen catalog in the app: the provider plays a recording through
/// its MP3 and names its licence, the loader fills the row when its switch
/// is on, and the source, the row, the area and the Browse lane exist as
/// for every other catalog.
@MainActor
struct MusopenSourceTests {
    nonisolated static let recording = MusopenCatalog.Recording(
        pageId: 99430846,
        title: "A Midsummer Night's Dream Op. 61 Dance of Clowns",
        artistHTML: "<a href=\"//commons.wikimedia.org/wiki/User:X\">European &amp; Archive</a>",
        duration: 120.3,
        licence: .publicDomain,
        audioURL: URL(string: "https://upload.wikimedia.org/wikipedia/commons/transcoded/4/4f/Clowns.ogg/Clowns.ogg.mp3")!,
        pageURL: URL(string: "https://commons.wikimedia.org/wiki/File:Clowns.ogg"))

    final class Asked {
        var pageIds: [Int] = []
    }

    private func makeProvider(allowed: Bool, answer: MusopenCatalog.Recording?) throws -> (FreeCatalogProvider, Asked, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("musopen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let provider = FreeCatalogProvider(ablage: Ablage(directory: directory))
        let asked = Asked()
        provider.fetchMusopenRecording = { id in asked.pageIds.append(id); return answer }
        provider.musopenAllowed = { allowed }
        return (provider, asked, directory)
    }

    @Test("A recording becomes a tile with its name and the artist as plain text")
    func tile() throws {
        let (provider, _, directory) = try makeProvider(allowed: true, answer: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = try #require(provider.remember(recording: Self.recording))
        #expect(item.id == "mso:99430846")
        #expect(item.title == "A Midsummer Night's Dream Op. 61 Dance of Clowns")
        #expect(item.author == "European & Archive")
        #expect(item.media?.duration == 120.3)
    }

    @Test("A recording plays as one track from its MP3, names its licence and its file page, and may be kept offline")
    func playback() async throws {
        let (provider, asked, directory) = try makeProvider(allowed: true, answer: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = provider.remember(recording: Self.recording)
        let detail = try await provider.fetchItemDetail(itemId: "mso:99430846")
        let tracks = try #require(detail.media.tracks)
        #expect(tracks.count == 1)
        #expect(tracks.first?.contentUrl == Self.recording.audioURL.absoluteString)
        #expect(provider.streamURL(forContentPath: tracks.first?.contentUrl ?? "") == Self.recording.audioURL)
        #expect(provider.licence(forItemId: "mso:99430846") == MusopenCatalog.Licence.publicDomain.label)
        #expect(provider.sourceURL(forItemId: "mso:99430846") == Self.recording.pageURL)
        #expect(provider.mayKeep(itemId: "mso:99430846"))
        #expect(asked.pageIds.isEmpty, "a recording the row showed is asked again")
    }

    @Test("A recording no row showed is asked once by its page id while the source is on")
    func coldStart() async throws {
        let (provider, asked, directory) = try makeProvider(allowed: true, answer: Self.recording)
        defer { try? FileManager.default.removeItem(at: directory) }
        let detail = try await provider.fetchItemDetail(itemId: "mso:99430846")
        #expect(asked.pageIds == [99430846])
        #expect(detail.media.tracks?.first?.contentUrl == Self.recording.audioURL.absoluteString)
    }

    @Test("With the source off nothing is asked, and the recording does not open")
    func sourceOff() async throws {
        let (provider, asked, directory) = try makeProvider(allowed: false, answer: Self.recording)
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: (any Error).self) { _ = try await provider.fetchItemDetail(itemId: "mso:99430846") }
        #expect(asked.pageIds.isEmpty)
    }

    @Test("The loader fills the Musopen row when its switch is on, says why when the answer fails, and asks nothing when it is off")
    func loaderRow() async throws {
        let recording = Self.recording
        var clients = CatalogLoaderWitness.failing()
        let asks = GutenbergWitness.Asks()
        clients.musopen = MusopenSeam(row: { _, _ in
            asks.add()
            return MusopenCatalog.Page(recordings: [recording], dropped: [.licence: 2], token: nil)
        })
        var gates = CatalogGates(librivox: false, archiveBooks: false, gutenberg: false, jamendo: false,
                                 freeAudiobooksArea: false, freeClassical: false, netlabels: false, languages: [])
        gates.musopen = true
        let rows = await FreeCatalogLoader.load(using: clients, gates: gates, dayStore: try #require(UserDefaults(suiteName: "musopen-\(UUID().uuidString)")))
        #expect(rows.musopen.map(\.id) == ["mso:99430846"])
        #expect(rows.problems[.musopen] == nil)
        #expect(asks.count == 1)

        clients.musopen = MusopenSeam(row: { _, _ in throw URLError(.notConnectedToInternet) })
        let failed = await FreeCatalogLoader.load(using: clients, gates: gates, dayStore: try #require(UserDefaults(suiteName: "musopen-\(UUID().uuidString)")))
        #expect(failed.musopen.isEmpty)
        #expect(failed.problems[.musopen] != nil, "a failed row says nothing")

        gates.musopen = false
        let offAsks = GutenbergWitness.Asks()
        clients.musopen = MusopenSeam(row: { _, _ in offAsks.add(); return MusopenCatalog.Page() })
        let off = await FreeCatalogLoader.load(using: clients, gates: gates, dayStore: try #require(UserDefaults(suiteName: "musopen-\(UUID().uuidString)")))
        #expect(off.musopen.isEmpty && offAsks.count == 0, "the row asked with its switch off")
    }

    @Test("Musopen is a catalog source of its own, with its own row switch, area and Browse lane in music")
    func structure() throws {
        let source = try #require(ExternalSources.source(key: "musopen"))
        #expect(source.group == .catalogs)
        #expect(source.hosts.contains("commons.wikimedia.org") && source.hosts.contains("upload.wikimedia.org"))
        let row = try #require(AppRows.row(key: "music.musopen"))
        #expect(row.tab == .music && row.sourceKeys == ["musopen"])
        #expect(row.storageKey != nil && row.storageKey != source.storageKey)
        #expect(FreeCatalog.Area.musopen.rowKey == "music.musopen")
        #expect(BrowseSection.musopen.group == .music && BrowseSection.musopen.sourceKeys == ["musopen"])
        #expect(FreeCatalog.allPrefixes.contains(MusopenCatalog.prefix))
        #expect(MediaFamily.of("mso:1") == .catalog)
        #expect(MediaFamily.isMusicByForm("mso:1"))
        #expect(!MediaFamily.booksTabMember("mso:1", markedForm: nil))
    }

    @Test("A recording is a single track of music: its page counts it as a track, and it may be offered for download")
    func recordingIsATrack() throws {
        #expect(ArchiveSeriesPage.isTrack("mso:99430846"))
        #expect(ArchiveSeriesPage.isTrack(FreeCatalog.jamendoPrefix + "1"))
        #expect(!ArchiveSeriesPage.isTrack(FreeCatalog.archivePrefix + "album"))
        #expect(!ArchiveSeriesPage.isTrack("lv:1"))
        let (provider, _, directory) = try makeProvider(allowed: true, answer: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = provider.remember(recording: Self.recording)
        #expect(MediaDownloadOffer.isPossible(provider.capabilities, mayKeep: provider.mayKeep(itemId: "mso:99430846")),
                "the menu entry would stay away for a recording")
    }

    @Test("The Musopen tile and the page of a recording carry the download entry of music", .needsTheSources)
    func downloadIsOffered() throws {
        let tile = try #require(ProjectFileIntegrityTests.sourceFiles()
            .first { $0.path.hasSuffix("/Sources/Views/Music/MusopenViews.swift") })
        let tileText = try SourceTree.text(tile)
        let menu = try #require(tileText.range(of: ".contextMenu {"), "the tile has no menu")
        #expect(tileText[menu.upperBound...].prefix(300).contains("MusicDownloadMenuItems(itemId: item.id)"),
                "the Musopen tile offers no download")
        let page = try #require(ProjectFileIntegrityTests.sourceFiles()
            .first { $0.path.hasSuffix("/Sources/Views/CatalogSourcePage.swift") })
        let pageText = try SourceTree.text(page)
        let actions = try #require(pageText.range(of: ".pageActions(\"album-actions\") {"), "the page has no menu")
        #expect(pageText[actions.upperBound...].prefix(500).contains("MusicDownloadMenuItems(itemId: itemId)"),
                "the page of a recording offers no download")
    }

    @Test("The Classical page carries the Musopen row, and the row opens the Musopen page", .needsTheSources)
    func classicalPageFence() throws {
        let page = try #require(ProjectFileIntegrityTests.sourceFiles()
            .first { $0.path.hasSuffix("/Sources/Views/Music/ArchiveMusicPages.swift") })
        let text = try SourceTree.text(page)
        #expect(text.contains("MusopenRow("), "the Classical page has no Musopen row")
        let row = try #require(ProjectFileIntegrityTests.sourceFiles()
            .first { $0.path.hasSuffix("/Sources/Views/Music/MusopenViews.swift") })
        #expect(try SourceTree.text(row).contains("MusicRoute.musopen"), "the Musopen row leads nowhere")
    }
}
#endif
