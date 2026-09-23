// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Combine
@testable import Maer

/// How often the downloader wakes an observer during one download. Counted
/// at the notifier, not at the screen: every observer of an
/// `ObservableObject` is woken by every `objectWillChange`, whatever it
/// reads. Each case runs over a documents directory of its own.
///
/// The download is the real `download(item:provider:kind:)` path without a
/// network: its tracks are already on disk, so the loop takes the
/// resume-by-skip branch and reports one step per track, then finishes the
/// way every download finishes.
@MainActor
struct DownloadNotifyCountTests {
    /// A source that gives every track an address; nothing is fetched,
    /// because every track is already there.
    final class AddressProvider: AudioProvider {
        var providerId: String { "address" }
        var capabilities: ProviderCapabilities { [.downloadable] }
        var streamAuthHeaders: [String: String] { [:] }
        func fetchLibraries() async throws -> [ABSLibrary] { [] }
        func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] { [] }
        func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
            throw NSError(domain: "address", code: 404)
        }
        func coverURL(forItemId itemId: String) -> URL? { nil }
        func streamURL(forContentPath contentPath: String) -> URL? { URL(string: "https://unused.test/\(contentPath)") }
        func fetchAllProgress() async throws -> [String: BookProgress] { [:] }
        func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}
        func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
        func createBookmark(itemId: String, time: Double, title: String) async throws {}
        func deleteBookmark(itemId: String, time: Double) async throws {}
    }

    struct Home {
        let directory: URL
        let manager: DownloadManager
    }

    static func home() throws -> Home {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-notify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path)
        return Home(directory: directory, manager: DownloadManager(documents: directory, database: database))
    }

    /// `count` tracks already on disk for `itemId`, each opening with an
    /// MPEG frame header so the audio sniffer takes it for a real track.
    static func plant(_ itemId: String, tracks count: Int, in home: Home) throws -> LibraryItemDetail {
        let folder = home.directory.appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(itemId, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var tracks: [ABSAudioTrack] = []
        for index in 0..<count {
            try (Data([0xFF, 0xFB, 0x90, 0x64]) + Data(repeating: 0, count: 400))
                .write(to: folder.appendingPathComponent("\(index).mp3"))
            tracks.append(ABSAudioTrack(index: index, startOffset: Double(index), duration: 1,
                                        contentUrl: "t\(index)", metadata: ABSFileMetadata(size: 404)))
        }
        return LibraryItemDetail(
            id: itemId,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(title: "Book", authorName: nil, narratorName: nil,
                                              seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                duration: Double(count), chapters: nil, tracks: tracks),
            userMediaProgress: nil)
    }

    @Test("heute: ein Download mit 100 Schritten weckt JEDEN Beobachter je Schritt")
    func todayEveryObserverWakesPerStep() async throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        await home.manager.ensureScanned()
        let detail = try Self.plant("book-1", tracks: 100, in: home)
        var woken = 0
        let listening = home.manager.objectWillChange.sink { woken += 1 }
        await home.manager.download(item: detail, provider: AddressProvider(), kind: .audiobooks)
        listening.cancel()
        #expect(home.manager.downloadedItemIds == ["book-1"], "the download finished, so it measured a whole one")
        // The start, one per track, and the finish (mark, phase cleared,
        // size): an observer that reads only the stock is woken each time.
        #expect(woken == 104, "gemessen: \(woken)")
    }
}
#endif
