// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A paused download belongs to the source it began with: a resume asks
/// that source for its tracks, whichever download started in between.
@MainActor
struct DownloadResumeSourceTests {
    /// A source that notes which track it was asked for and names no
    /// address, so nothing goes out.
    final class NotingSource: AudioProvider {
        private(set) var asked: [String] = []
        var providerId: String { "noting" }
        var keepsMarksOnDevice: Bool { true }
        var capabilities: ProviderCapabilities { [.downloadable] }
        var streamAuthHeaders: [String: String] { [:] }
        func fetchLibraries() async throws -> [ABSLibrary] { [] }
        func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] { [] }
        func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail { throw NSError(domain: "noting", code: 404) }
        func coverURL(forItemId itemId: String) -> URL? { nil }
        func streamURL(forContentPath contentPath: String) -> URL? {
            asked.append(contentPath)
            return nil
        }
        func fetchAllProgress() async throws -> [String: BookProgress] { [:] }
        func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}
        func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
        func createBookmark(itemId: String, time: Double, title: String) async throws {}
        func deleteBookmark(itemId: String, time: Double) async throws {}
    }

    private static func manager(in directory: URL) async -> DownloadManager {
        let database = MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path)
        let manager = DownloadManager(documents: directory, database: database)
        await manager.ensureScanned()
        return manager
    }

    @Test("a paused download is resumed with the source it began with, even if another download began in between")
    func aResumeAsksTheSourceTheDownloadBeganWith() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("resume-source-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = await Self.manager(in: directory)
        let own = NotingSource()
        let other = NotingSource()
        let book = "resume-book-\(UUID().uuidString)"
        let album = "resume-album-\(UUID().uuidString)"
        manager._testHoldAsPaused(TrackFileSizeTests.book(book, path: "book.mp3", size: 10), provider: own)

        await manager.download(item: TrackFileSizeTests.book(album, path: "album.mp3", size: 10), provider: other, kind: nil)
        #expect(other.asked == ["album.mp3"], "the other download asked its own source: \(other.asked)")

        manager.resumeDownload(itemId: book)
        for _ in 0..<2_000 where !(own.asked + other.asked).contains("book.mp3") { await Task.yield() }
        #expect(own.asked == ["book.mp3"], "the resume did not ask the source the download began with: \(own.asked)")
        #expect(other.asked == ["album.mp3"], "the resume asked the source of the download that started last: \(other.asked)")
    }

    @Test("if the source of a paused download is gone, the resume says so and does not stay paused")
    func aResumeWithoutItsSourceSaysSo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("resume-gone-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = await Self.manager(in: directory)
        let book = "resume-book-\(UUID().uuidString)"
        manager._testHoldAsPaused(TrackFileSizeTests.book(book, path: "book.mp3", size: 10), provider: nil)
        #expect(manager.phase[book] == .paused(0))

        manager.resumeDownload(itemId: book)
        #expect(manager.phase[book] == .failed(String(localized: "Not available on this device: the source is not set up here")),
                "the title stays paused without a way on: \(String(describing: manager.phase[book]))")
    }
}
#endif
