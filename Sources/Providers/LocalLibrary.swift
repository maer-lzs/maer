import Foundation
import Combine
import AVFoundation
import UIKit

/// Persistenter Index der importierten lokalen Audiodateien. Jede Datei (oder
/// ein importierter Ordner mit mehreren Dateien = ein mehrteiliges Hörbuch)
/// wird zu einem `LibraryItem` mit `local:`-ID. Dateien liegen im
/// App-Container unter `LocalAudio/<uuid>/`; Metadaten (Titel, Autor, Dauer,
/// Kapitel, Cover) werden beim Import per AVAsset extrahiert und im Index
/// gespeichert, damit die Bibliothek offline ohne erneutes Parsen lädt.
@MainActor
final class LocalLibrary: ObservableObject {
    static let shared = LocalLibrary()

    /// Ein importiertes Element (persistierte Metadaten + Dateiliste).
    struct Entry: Codable, Identifiable {
        var id: String                 // "local:<uuid>"
        var title: String
        var author: String?
        var duration: Double
        var addedAt: Double
        /// Track-Dateinamen relativ zum Item-Ordner, in Abspielreihenfolge.
        var trackFiles: [String]
        var chapters: [ABSChapter]
        /// true, wenn beim Import ein Cover extrahiert wurde (cover.jpg).
        var hasCover: Bool
    }

    @Published private(set) var entries: [Entry] = []

    private let indexURL: URL
    private let audioDir: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        audioDir = docs.appendingPathComponent("LocalAudio", isDirectory: true)
        indexURL = docs.appendingPathComponent("local_library.json")
        if !FileManager.default.fileExists(atPath: audioDir.path) {
            try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        }
        load()
    }

    // MARK: - Provider-Daten

    /// Alle Einträge als `LibraryItem` (für die Bibliotheksliste).
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

    /// Lokale Datei-URL eines Tracks anhand des Stream-Pfads (contentUrl =
    /// "<uuid>/<dateiname>").
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

    /// Kopiert ausgewählte Audiodateien in den Container und legt EINEN
    /// Eintrag an (mehrere Dateien = ein mehrteiliges Hörbuch, alphabetisch
    /// sortiert). Metadaten kommen aus der ersten Datei.
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
        // Cover extrahieren (aus dem ersten Track).
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
        // Pro-Buch-Keys (Position, Rate) mit aufräumen.
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.localPosition(id))
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.playbackRate(id))
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

    private nonisolated static func extractMetadata(dir: URL, files: [String]) async -> ExtractedMetadata {
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
            // Metadaten nur aus der ersten Datei.
            if index == 0, let items = try? await asset.load(.commonMetadata) {
                for item in items {
                    if item.commonKey == .commonKeyTitle, let v = try? await item.load(.stringValue) { title = v }
                    if item.commonKey == .commonKeyArtist, let v = try? await item.load(.stringValue) { author = v }
                    if item.commonKey == .commonKeyArtwork, let v = try? await item.load(.dataValue) { artwork = v }
                }
            }
            // Eingebettete Kapitel je Datei (Zeiten auf die Gesamtposition heben).
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

        // Mehrteilig ohne eingebettete Kapitel: jede Datei = ein Kapitel.
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

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
