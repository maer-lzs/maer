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
/// `local_library`; the document of the builds before is poured once and
/// set aside, an unreadable one stays `.corrupt` and is never poured.
@MainActor
final class LocalLibrary: ObservableObject {
    static let shared = LocalLibrary(
        database: MaerDatabase.shared,
        ablage: .documents,
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

    /// The seam to disk for the document of the builds before.
    private let ablage: Ablage
    private let documentName = "local_library.json"
    private let audioDir: URL
    private let keeper: RowKeeper<Entry>

    init(database: MaerDatabase, ablage: Ablage, audioDir: URL) {
        self.ablage = ablage
        self.audioDir = audioDir
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
    /// "<uuid>/<filename>").
    func fileURL(forContentPath contentPath: String) -> URL? {
        let url = audioDir.appendingPathComponent(contentPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func coverURL(forItemId itemId: String) -> URL? {
        guard let entry = entries.first(where: { $0.id == itemId }), entry.hasCover else { return nil }
        return itemDir(entry).appendingPathComponent("cover.jpg")
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

    private func itemDir(_ entry: Entry) -> URL {
        audioDir.appendingPathComponent(uuid(entry), isDirectory: true)
    }

    // MARK: - Import

    /// Copies selected audio files into the container and creates ONE entry
    /// (several files = one multi-file audiobook, alphabetically sorted).
    /// Metadata comes from the first file.
    func importFiles(_ urls: [URL]) async {
        let audioURLs = urls.filter { Self.isAudioFile($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !audioURLs.isEmpty else { return }

        let uuid = UUID().uuidString
        let dir = audioDir.appendingPathComponent(uuid, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var trackFiles: [String] = []
        for url in audioURLs {
            let needsStop = url.startAccessingSecurityScopedResource()
            defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
            let dest = dir.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                trackFiles.append(url.lastPathComponent)
            }
        }
        guard !trackFiles.isEmpty else { return }

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
        save()
    }

    func delete(id: String) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: itemDir(entry))
        entries.removeAll { $0.id == id }
        save()
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

    /// The rows first; the document only when the rows hold nothing, poured
    /// once. An unreadable index must not become an empty one: the seam
    /// keeps it aside as `.corrupt`, nothing is poured, and nothing writes
    /// the document again. A failed row read falls back to the document that
    /// was set aside and migrates nothing.
    private func load() {
        let start = keeper.startNow()
        var loaded: [Entry]? = start.rows.map { Array($0.values) }
        var document: URL?
        if loaded == nil {
            if let decoded = ablage.loadNow([Entry].self, name: documentName).value {
                loaded = decoded
                document = ablage.url(for: documentName)
            }
            if start.failed {
                loaded = loaded ?? ablage.loadNow([Entry].self, name: documentName + ".migrated").value
                document = nil
            }
        }
        entries = (loaded ?? []).sorted { $0.addedAt > $1.addedAt }
        Logger.library.notice("LOCALLIB start: entries=\(self.entries.count) migrate=\(document != nil)")
        if let document { keeper.pour(Self.keyed(entries), settingAside: [document]) }
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
    /// on in memory.
    private func save() {
        keeper.write(Self.keyed(entries))
    }
}
