// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog
import Combine
import AVFoundation
import UIKit

/// Persistent index of the imported local audio files. Each file (or an
/// imported folder with several files = one multi-file audiobook) becomes a
/// `LibraryItem` with a `local:` id. Files live in the app container under
/// `LocalAudio/<uuid>/`; metadata (title, author, duration, chapters, cover) is
/// extracted via AVAsset on import and stored in the index so the library loads
/// offline without re-parsing. The index is one row per item in
/// `local_library`.
@MainActor
final class LocalLibrary: ObservableObject {
    static let shared = LocalLibrary(
        database: MaerDatabase.shared,
        audioDir: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalAudio", isDirectory: true)
    )

    /// An imported item (persisted metadata + file list).
    // nonisolated: the rows encode and decode the index off the main actor.
    nonisolated struct Entry: Codable, Identifiable, Equatable, Sendable {
        var id: String                 // "local:<uuid>"
        var title: String
        var author: String?
        var duration: Double
        var addedAt: Double
        /// Track filenames relative to the item folder, in playback order.
        var trackFiles: [String]
        var chapters: [ABSChapter]
        /// true if a cover was extracted on import (cover.jpg).
        var hasCover: Bool
    }

    /// Newest first, the order the shelf shows and the import inserts.
    @Published private(set) var entries: [Entry] = []

    /// Where the import writes its copies.
    private let container: LocalContainerRoot
    /// Where every read and every removal asks; the container unless a
    /// witness hands in another.
    private let root: any LocalFileRoot
    private let keeper: RowKeeper<Entry>

    init(database: MaerDatabase, audioDir: URL, root: (any LocalFileRoot)? = nil) {
        self.container = LocalContainerRoot(audioDir: audioDir)
        self.root = root ?? container
        self.keeper = RowKeeper(database: database, table: .localLibrary, label: "LOCALLIB")
        if !FileManager.default.fileExists(atPath: audioDir.path) {
            try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        }
        load()
    }

    // MARK: - Provider-Daten

    /// All entries as `LibraryItem` (for the library list).
    func libraryItems() -> [LibraryItem] {
        entries.map { entry in
            LibraryItem(
                id: entry.id,
                media: media(for: entry),
                addedAt: entry.addedAt
            )
        }
    }

    func itemDetail(id: String) -> LibraryItemDetail? {
        guard let entry = entries.first(where: { $0.id == id }) else { return nil }
        return LibraryItemDetail(id: entry.id, media: media(for: entry), userMediaProgress: nil)
    }

    /// Local file URL of a track from the stream path (contentUrl =
    /// "<uuid>/<filename>"), in the folder its entry's root names.
    func fileURL(forContentPath contentPath: String) -> URL? {
        guard let slash = contentPath.firstIndex(of: "/"),
              let folder = root.folder(forEntry: "local:\(contentPath[..<slash])") else { return nil }
        let url = folder.appendingPathComponent(String(contentPath[contentPath.index(after: slash)...]))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func coverURL(forItemId itemId: String) -> URL? {
        guard let entry = entries.first(where: { $0.id == itemId }), entry.hasCover else { return nil }
        return root.folder(forEntry: entry.id)?.appendingPathComponent("cover.jpg")
    }

    private func media(for entry: Entry) -> LibraryItemMedia {
        let tracks = entry.trackFiles.enumerated().map { index, file in
            ABSAudioTrack(
                index: index,
                startOffset: nil,
                duration: nil,
                contentUrl: "\(uuid(entry))/\(file)",
                metadata: nil
            )
        }
        return LibraryItemMedia(
            metadata: LibraryItemMetadata(
                title: entry.title,
                authorName: entry.author,
                narratorName: nil,
                seriesName: nil,
                genres: nil,
                publishedYear: nil,
                description: nil
            ),
            duration: entry.duration,
            chapters: entry.chapters.isEmpty ? nil : entry.chapters,
            tracks: tracks
        )
    }

    private func uuid(_ entry: Entry) -> String {
        String(entry.id.dropFirst("local:".count))
    }

    // MARK: - Import

    /// Copies selected audio files into the container and creates ONE entry
    /// (several files = one multi-file audiobook, alphabetically sorted).
    /// Metadata comes from the first file.
    /// Copies the chosen audio files into one new entry. Returns how many of
    /// them could NOT be taken over, so the page can say so; each failure
    /// also leaves a log line with its reason and the file's extension, never
    /// its name (a file name can be private).
    @discardableResult
    func importFiles(_ urls: [URL]) async -> Int {
        let audioURLs = urls.filter { Self.isAudioFile($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !audioURLs.isEmpty else { return 0 }

        let uuid = UUID().uuidString
        // An import is a copy, so it always writes into the container.
        let dir = container.folder(forUUID: uuid)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var trackFiles: [String] = []
        var failed = 0
        for url in audioURLs {
            let needsStop = url.startAccessingSecurityScopedResource()
            defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
            let dest = dir.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                trackFiles.append(url.lastPathComponent)
            } catch {
                failed += 1
                // The extension only: a file name can be private.
                let kind = url.pathExtension.lowercased()
                Logger.library.error("LOCALLIB import copy failed reason=\(FailureReason.of(error), privacy: .public) ext=\(kind, privacy: .public)")
            }
        }
        guard !trackFiles.isEmpty else {
            // Nothing arrived: no entry, and no empty folder left behind.
            try? FileManager.default.removeItem(at: dir)
            return failed
        }

        let meta = await Self.extractMetadata(dir: dir, files: trackFiles)
        // Extract the cover (from the first track).
        var hasCover = false
        if let artwork = meta.artwork {
            let coverURL = dir.appendingPathComponent("cover.jpg")
            if (try? artwork.write(to: coverURL, options: .atomic)) != nil { hasCover = true }
        }

        let entry = Entry(
            id: "local:\(uuid)",
            title: meta.title ?? audioURLs[0].deletingPathExtension().lastPathComponent,
            author: meta.author,
            duration: meta.duration,
            addedAt: Date().timeIntervalSince1970 * 1000,
            trackFiles: trackFiles,
            chapters: meta.chapters,
            hasCover: hasCover
        )
        entries.insert(entry, at: 0)
        save(emptying: .refused)
        return failed
    }

    func delete(id: String) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        root.removeFiles(ofEntry: entry.id)
        entries.removeAll { $0.id == id }
        save(emptying: .allowed)
        // The ONE legitimate removal: the user deleted the item itself, so
        // its state has nothing left to belong to. Every other path replaces
        // instead of removing.
        ListeningStore.forgetUserDeleted(id)
        AppStorageKeys.remove(AppStorageKeys.playbackRate(id))
    }

    private static func isAudioFile(_ url: URL) -> Bool {
        ["mp3", "m4a", "m4b", "aac", "flac", "wav", "aiff", "aif", "ogg", "opus", "caf"]
            .contains(url.pathExtension.lowercased())
    }

    // MARK: - Metadaten-Extraktion

    private struct ExtractedMetadata {
        var title: String?
        var author: String?
        var duration: Double
        var chapters: [ABSChapter]
        var artwork: Data?
    }

    // `@concurrent`: force off the caller's executor. Under the project's default
    // MainActor isolation a plain `nonisolated async` would run the AVAsset load
    // orchestration on the calling MainActor; @concurrent keeps it off-main.
    @concurrent private nonisolated static func extractMetadata(dir: URL, files: [String]) async -> ExtractedMetadata {
        var totalDuration: Double = 0
        var title: String?
        var author: String?
        var artwork: Data?
        var chapters: [ABSChapter] = []

        for (index, file) in files.enumerated() {
            let asset = AVURLAsset(url: dir.appendingPathComponent(file))
            let start = totalDuration
            if let duration = try? await asset.load(.duration) {
                totalDuration += duration.seconds.isFinite ? duration.seconds : 0
            }
            // Metadata only from the first file.
            if index == 0, let items = try? await asset.load(.commonMetadata) {
                for item in items {
                    if item.commonKey == .commonKeyTitle, let v = try? await item.load(.stringValue) { title = v }
                    if item.commonKey == .commonKeyArtist, let v = try? await item.load(.stringValue) { author = v }
                    if item.commonKey == .commonKeyArtwork, let v = try? await item.load(.dataValue) { artwork = v }
                }
            }
            // Embedded chapters per file (lift times to the overall position).
            if let groups = try? await asset.loadChapterMetadataGroups(
                bestMatchingPreferredLanguages: Locale.preferredLanguages
            ) {
                for group in groups {
                    let time = group.timeRange.start.seconds
                    var chapterTitle = ""
                    if let titleItem = group.items.first(where: { $0.commonKey == .commonKeyTitle }),
                       let v = try? await titleItem.load(.stringValue) { chapterTitle = v }
                    chapters.append(ABSChapter(
                        id: chapters.count,
                        start: start + (time.isFinite ? time : 0),
                        end: start + (group.timeRange.end.seconds.isFinite ? group.timeRange.end.seconds : 0),
                        title: chapterTitle.isEmpty ? String(localized: "Chapter \(chapters.count + 1)") : chapterTitle
                    ))
                }
            }
        }

        // Multi-file without embedded chapters: each file = one chapter.
        if chapters.isEmpty && files.count > 1 {
            var offset: Double = 0
            for (index, file) in files.enumerated() {
                let asset = AVURLAsset(url: dir.appendingPathComponent(file))
                let dur = (try? await asset.load(.duration))?.seconds ?? 0
                chapters.append(ABSChapter(
                    id: index,
                    start: offset,
                    end: offset + dur,
                    title: URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
                ))
                offset += dur.isFinite ? dur : 0
            }
        }

        return ExtractedMetadata(title: title, author: author, duration: totalDuration, chapters: chapters, artwork: artwork)
    }

    // MARK: - Persistenz

    /// The rows; a read that could not read every row leaves the base
    /// unknown, so a write removes only rows it read.
    private func load() {
        entries = (keeper.startNow() ?? [:]).values.sorted { $0.addedAt > $1.addedAt }
        Logger.library.notice("LOCALLIB start: entries=\(self.entries.count)")
    }

    /// The index as rows: one per item, keyed by its id.
    private nonisolated static func keyed(_ entries: [Entry]) -> [String: Entry] {
        Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
    }

    /// Waits for every queued write of the rows (tests, teardown).
    func awaitPendingWrites() async {
        await keeper.awaitPendingWrites()
    }

    /// The rows get the diff; the keeper logs a failure and the index lives
    /// on in memory. `emptying` is `.allowed` only where the user deleted.
    private func save(emptying: RowEmptying) {
        keeper.write(Self.keyed(entries), emptying: emptying)
    }
}
