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
        var keepsMarksOnDevice: Bool { true }
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

    /// The stock's sizes are the disk's answer: exactly the downloaded items,
    /// each with the size its folder has, and the sum as the total.
    static func sizesMatchTheDisk(_ manager: DownloadManager) -> Bool {
        let sizes = manager.stock.sizeByItem
        return Set(sizes.keys) == manager.downloadedItemIds
            && sizes.allSatisfy { $0.value == manager.downloadSize(forItemId: $0.key) }
            && manager.totalDownloadsSize == sizes.values.reduce(0, +)
    }

    @Test("nach jedem Weg, der Dateien aendert, stimmen die Groessen des Bestands mit der Platte")
    func sizesFollowEveryWay() async throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let provider = AddressProvider()
        // Finish.
        await home.manager.ensureScanned()
        let one = try Self.plant("book-1", tracks: 3, in: home)
        await home.manager.download(item: one, provider: provider, kind: .audiobooks)
        let two = try Self.plant("book-2", tracks: 2, in: home)
        await home.manager.download(item: two, provider: provider, kind: .audiobooks)
        #expect(home.manager.stock.sizeByItem["book-1"] == Int64(3 * 404), "the finish measured the folder")
        #expect(Self.sizesMatchTheDisk(home.manager), "Abschluss")
        // Load Missing Files ends in the same finish as a first download;
        // its transfer needs a network (the background session refuses a
        // file address), so the finish above stands for it.
        // Scan: a manager of its own over the same disk.
        await home.manager.awaitPendingWrites()
        let database = MaerDatabase(path: home.directory.appendingPathComponent("maer.sqlite").path)
        let rescanned = DownloadManager(documents: home.directory, database: database)
        await rescanned.ensureScanned()
        #expect(rescanned.downloadedItemIds == ["book-1", "book-2"], "the scan found both")
        #expect(Self.sizesMatchTheDisk(rescanned), "Scan")
        // Adopt: the folder moves whole, the size moves with its key.
        #expect(home.manager.adoptDownload(from: "book-2", to: "book-2b"))
        #expect(home.manager.stock.sizeByItem["book-2b"] == Int64(2 * 404) && home.manager.stock.sizeByItem["book-2"] == nil)
        #expect(Self.sizesMatchTheDisk(home.manager), "Uebernehmen")
        // Delete, then delete all.
        home.manager.deleteDownload(itemId: "book-1")
        #expect(Self.sizesMatchTheDisk(home.manager), "Loeschen")
        home.manager.deleteAllDownloads()
        #expect(home.manager.stock.sizeByItem.isEmpty && home.manager.totalDownloadsSize == 0)
        #expect(Self.sizesMatchTheDisk(home.manager), "Alles loeschen")
    }

    // MARK: Fences

    @Test("niemand beobachtet den Downloader oder den ganzen Fortschritt, nur den Bestand und das Objekt eines Eintrags")
    func nobodyObservesTheManager() {
        // A conformance put back would make every observer of it a waker of
        // all again; any path to its `objectWillChange` goes with it.
        #expect(!((DownloadManager.shared as AnyObject) is any ObservableObject))
        #expect(!((DownloadManager.progress as AnyObject) is any ObservableObject),
                "the whole progress table would wake every cover for every download")
        #expect((DownloadManager.stock as AnyObject) is any ObservableObject)
        #expect((DownloadManager.progress.item("x") as AnyObject) is any ObservableObject)
    }

    @Test("ein Eintrag wacht fuer seinen eigenen Download auf, nicht fuer einen anderen, und sieht das Ende")
    func anItemWakesForItsOwnDownloadAndSeesTheEnd() async throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        await home.manager.ensureScanned()
        let detail = try Self.plant("book-1", tracks: 100, in: home)
        // Taken BEFORE the download starts, the way a cover takes it.
        let own = home.manager.progress.item("book-1")
        let other = home.manager.progress.item("book-2")
        var ownWoken = 0
        var otherWoken = 0
        var seen: [DownloadManager.DownloadPhase?] = []
        let a = own.objectWillChange.sink { ownWoken += 1 }
        let b = other.objectWillChange.sink { otherWoken += 1 }
        let c = own.$phase.sink { seen.append($0) }
        await home.manager.download(item: detail, provider: AddressProvider(), kind: .audiobooks)
        a.cancel(); b.cancel(); c.cancel()
        #expect(home.manager.downloadedItemIds == ["book-1"], "the download finished, so it measured a whole one")
        #expect(ownWoken == 102, "der eigene Eintrag: Start, je Spur einer, das Ende: \(ownWoken)")
        #expect(otherWoken == 0, "ein anderer Eintrag wacht nicht auf: \(otherWoken)")
        // The end state reached the object that was held all along.
        #expect(own.phase == nil)
        #expect(seen.first == .some(nil) && seen.dropFirst().first == .some(.downloading(0)) && seen.last == .some(nil),
                "das Objekt sah Anfang und Ende: \(seen.count) Werte")
        #expect(home.manager.progress.item("book-1") === own, "while held, the item keeps its one object")
    }

    @Test("auch ein Abbruch und ein Fehlschlag erreichen das gehaltene Objekt")
    func failureReachesTheHeldObject() async throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        await home.manager.ensureScanned()
        let held = home.manager.progress.item("empty")
        // A book without tracks fails at once, the way a real one can.
        let detail = LibraryItemDetail(
            id: "empty",
            media: LibraryItemMedia(metadata: nil, duration: 0, chapters: nil, tracks: []),
            userMediaProgress: nil)
        await home.manager.download(item: detail, provider: AddressProvider(), kind: .audiobooks)
        if case .failed = held.phase {} else { Issue.record("das gehaltene Objekt sah den Fehlschlag nicht: \(String(describing: held.phase))") }
    }

    /// The bodies of the types that observe the progress notifier, each
    /// with whether it reads progress (`phase`, `isDownloading`).
    nonisolated static func progressObservers(in text: String) -> [(type: String, reads: Bool)] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            String($0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        }
        var out: [(String, Bool)] = []
        for (index, line) in lines.enumerated() where line.contains("DownloadManager.progress.item(") {
            var start = index
            while start > 0, lines[start].range(of: #"^\s*(private |fileprivate )?struct \w+"#, options: .regularExpression) == nil {
                start -= 1
            }
            let name = lines[start].range(of: #"struct \w+"#, options: .regularExpression).map { String(lines[start][$0]) } ?? "?"
            var depth = 0, started = false, body: [String] = []
            for line in lines[start...] {
                depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
                body.append(line)
                if line.contains("{") { started = true }
                if started, depth <= 0 { break }
            }
            let code = body.joined(separator: "\n")
            out.append((name, code.contains(".phase") || code.contains("isDownloading(")))
        }
        return out
    }

    @Test("wer den Fortschritt beobachtet, liest ihn; keine Ansicht liest Groessen von der Platte", .needsTheSources)
    func progressObserversReadProgress() throws {
        let root = SourceTree.root.appendingPathComponent("Sources/Views")
        var observers: [(type: String, reads: Bool)] = []
        var diskReads: [String] = []
        for url in SourceTree.files(under: root) where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            observers += Self.progressObservers(in: text)
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            if code.contains(where: { $0.contains("downloadSize(forItemId") }) { diskReads.append(url.lastPathComponent) }
        }
        #expect(observers.count == 7, "sieben Fortschritts-Beobachter: \(observers.map(\.type))")
        let idleObservers = observers.filter { !$0.reads }.map(\.type)
        #expect(idleObservers.isEmpty, "beobachtet den Fortschritt, liest ihn nicht: \(idleObservers)")
        #expect(diskReads.isEmpty, "eine Ansicht liest Groessen von der Platte: \(diskReads)")
        let reads = "struct A: View {\n    @ObservedObject private var downloadProgress: ItemDownloadProgress\n    init(id: String) { _downloadProgress = ObservedObject(wrappedValue: DownloadManager.progress.item(id)) }\n    var body: some View { Text(\"\\(m.phase[id] == nil)\") }\n}"
        let idle = "struct B: View {\n    @ObservedObject private var downloadProgress: ItemDownloadProgress\n    init(id: String) { _downloadProgress = ObservedObject(wrappedValue: DownloadManager.progress.item(id)) }\n    var body: some View { Text(\"x\") }\n}"
        #expect(Self.progressObservers(in: reads).map(\.reads) == [true])
        #expect(Self.progressObservers(in: idle).map(\.reads) == [false], "ein Beobachter ohne Lesung wird gesehen")
    }

    /// Before the split (measured): one notifier, 104 wakes
    /// for every observer. Now each observer is woken by what it reads.
    @Test("ein Download mit 100 Schritten weckt den Bestand 3 Mal und den Fortschritt 102 Mal, vorher jeden 104 Mal")
    func eachNotifierWakesForWhatItCarries() async throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        await home.manager.ensureScanned()
        let detail = try Self.plant("book-1", tracks: 100, in: home)
        var stockWoken = 0
        let stock = home.manager.stock.objectWillChange.sink { stockWoken += 1 }
        await home.manager.download(item: detail, provider: AddressProvider(), kind: .audiobooks)
        stock.cancel()
        #expect(home.manager.downloadedItemIds == ["book-1"], "the download finished, so it measured a whole one")
        // The stock changes once, at the finish: the mark, the sizes, the sum.
        // The progress (102 for this download) reaches only the item's own
        // object, measured in the case below.
        #expect(stockWoken == 3, "Bestand gemessen: \(stockWoken)")
    }
}
#endif
