import Foundation
import Combine

/// Verwaltet lokal heruntergeladene Hörbücher. Jedes Buch bekommt einen
/// eigenen Unterordner "Downloads/{itemId}/0.{ext}", "1.{ext}", ... — auch
/// mehrteilige Bücher (mehrere Audiodateien statt einer M4B) werden komplett
/// heruntergeladen, nicht nur die erste Datei. Die zugehörigen Buchdetails
/// (Kapitel, Dauer, Track-Reihenfolge) liegen separat unter
/// "DownloadsMeta/{itemId}.json".
///
/// Die Metadaten-Datei ist der Schlüssel für echtes Offline-Hören: ohne sie
/// müsste die App bei jedem Öffnen eines Buchs erst Kapitel/Dauer vom Server
/// nachladen — selbst wenn die Audiodateien längst lokal vorliegen.
///
/// Bewusst als geräteweiter Singleton wie `KeychainStore`: Downloads sind ein
/// Geräte-Speicher-Konzept, keine Session-spezifische Abhängigkeit.
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var downloadedItemIds: Set<String> = []
    /// Fortschritt (0...1) pro Buch, über alle Tracks hinweg gewichtet.
    @Published private(set) var downloadProgress: [String: Double] = [:]
    @Published var errorMessage: String?

    private init() {
        downloadedItemIds = Set(scanExistingDownloads())
    }

    private var downloadsDirectory: URL {
        makeDirectory(named: "Downloads")
    }

    private var metadataDirectory: URL {
        makeDirectory(named: "DownloadsMeta")
    }

    private func itemDirectory(_ itemId: String) -> URL {
        downloadsDirectory.appendingPathComponent(itemId, isDirectory: true)
    }

    private func makeDirectory(named name: String) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Jedes Buch liegt in einem eigenen Unterordner (benannt nach der
    /// Item-ID) — Buch-IDs von Audiobookshelf können selbst Unterstriche
    /// enthalten, ein Unterordner pro Buch vermeidet jede Mehrdeutigkeit
    /// beim Zuordnen von Dateien zu Büchern.
    private func scanExistingDownloads() -> [String] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: downloadsDirectory, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return dirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { $0.lastPathComponent }
    }

    func isDownloaded(itemId: String) -> Bool {
        downloadedItemIds.contains(itemId)
    }

    func isDownloading(itemId: String) -> Bool {
        downloadProgress[itemId] != nil
    }

    /// Alle lokal heruntergeladenen Audiodateien eines Buchs, sortiert nach
    /// Track-Reihenfolge (Dateiname = Track-Index). Wird vom Player bevorzugt
    /// genutzt, um Streaming (und damit Latenz/Datenvolumen) zu vermeiden.
    func localFileURLs(forItemId itemId: String) -> [URL]? {
        let dir = itemDirectory(itemId)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ), !files.isEmpty else { return nil }
        return files.sorted { lhs, rhs in
            let li = Int(lhs.deletingPathExtension().lastPathComponent) ?? 0
            let ri = Int(rhs.deletingPathExtension().lastPathComponent) ?? 0
            return li < ri
        }
    }

    /// Zwischengespeicherte Buchdetails (Kapitel, Dauer, Tracks) für den
    /// Offline-Fall — wird geladen, wenn der Server nicht erreichbar ist,
    /// das Buch aber lokal heruntergeladen wurde.
    func loadCachedDetail(forItemId itemId: String) -> LibraryItemDetail? {
        let url = metadataDirectory.appendingPathComponent("\(itemId).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LibraryItemDetail.self, from: data)
    }

    private func saveDetail(_ detail: LibraryItemDetail) {
        let url = metadataDirectory.appendingPathComponent("\(detail.id).json")
        guard let data = try? JSONEncoder().encode(detail) else { return }
        try? data.write(to: url)
    }

    /// Lädt alle Tracks eines Buchs herunter (bei M4B-Büchern ist das nur
    /// einer, bei mehrteiligen Büchern mehrere) — nacheinander, mit über alle
    /// Tracks gewichtetem Gesamtfortschritt.
    func download(item: LibraryItemDetail, apiClient: APIClient) async {
        guard !isDownloaded(itemId: item.id), !isDownloading(itemId: item.id) else { return }
        let tracks = (item.media.tracks ?? []).sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        guard !tracks.isEmpty else {
            errorMessage = "Kein herunterladbarer Track gefunden."
            return
        }

        let itemId = item.id
        downloadProgress[itemId] = 0
        let dir = itemDirectory(itemId)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let perTrackWeight = 1.0 / Double(tracks.count)
        var completedFraction: Double = 0

        do {
            for (index, track) in tracks.enumerated() {
                guard let remoteURL = apiClient.streamURL(forContentPath: track.contentUrl) else { continue }
                var request = URLRequest(url: remoteURL)
                if let token = apiClient.token, !token.isEmpty {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }

                let baseProgress = completedFraction
                let downloader = FileDownloader { fraction in
                    Task { @MainActor in
                        DownloadManager.shared.downloadProgress[itemId] = baseProgress + fraction * perTrackWeight
                    }
                }

                let tempURL = try await downloader.download(request: request)
                let ext = remoteURL.pathExtension.isEmpty ? "m4b" : remoteURL.pathExtension
                let destination = dir.appendingPathComponent("\(index).\(ext)")
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: tempURL, to: destination)

                // Von iCloud-/Geräte-Backups ausschließen — Hörbücher sind
                // groß und gehören nicht ins iPhone-Backup.
                var destinationVar = destination
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = true
                try? destinationVar.setResourceValues(resourceValues)

                completedFraction += perTrackWeight
            }

            // Buchdetails (Kapitel, Dauer, Tracks) fürs echte Offline-Öffnen
            // mitspeichern — ohne das bräuchte selbst ein heruntergeladenes
            // Buch beim Öffnen noch eine Serveranfrage.
            saveDetail(item)

            downloadedItemIds.insert(itemId)
            downloadProgress[itemId] = nil
        } catch {
            errorMessage = "Download fehlgeschlagen: \(error.localizedDescription)"
            downloadProgress[itemId] = nil
            // Unvollständigen Download nicht als "fertig" stehen lassen.
            try? FileManager.default.removeItem(at: dir)
        }
    }

    func deleteDownload(itemId: String) {
        try? FileManager.default.removeItem(at: itemDirectory(itemId))
        let metaURL = metadataDirectory.appendingPathComponent("\(itemId).json")
        try? FileManager.default.removeItem(at: metaURL)
        downloadedItemIds.remove(itemId)
    }
}
