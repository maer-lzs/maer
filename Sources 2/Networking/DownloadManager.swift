import Foundation
import Combine

/// Verwaltet lokal heruntergeladene Hörbücher. Speichert Dateien im
/// App-Dokumentenordner unter "Downloads/{itemId}.{ext}" — der Dateiname
/// selbst ist der Persistenz-Mechanismus, keine zusätzliche Datenbank nötig.
///
/// Bewusst als geräteweiter Singleton wie `KeychainStore`: Downloads sind ein
/// Geräte-Speicher-Konzept, keine Session-spezifische Abhängigkeit.
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var downloadedItemIds: Set<String> = []
    /// Fortschritt (0...1) pro Buch, während ein Download läuft. Ein Eintrag
    /// hier bedeutet "wird gerade heruntergeladen".
    @Published private(set) var downloadProgress: [String: Double] = [:]
    @Published var errorMessage: String?

    private init() {
        downloadedItemIds = Set(scanExistingDownloads())
    }

    private var downloadsDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func scanExistingDownloads() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: downloadsDirectory, includingPropertiesForKeys: nil
        ) else { return [] }
        return files.map { $0.deletingPathExtension().lastPathComponent }
    }

    func isDownloaded(itemId: String) -> Bool {
        downloadedItemIds.contains(itemId)
    }

    func isDownloading(itemId: String) -> Bool {
        downloadProgress[itemId] != nil
    }

    /// Lokale Datei-URL, falls das Buch heruntergeladen ist. Wird vom Player
    /// bevorzugt genutzt, um Streaming (und damit Latenz/Datenvolumen) zu
    /// vermeiden.
    func localFileURL(forItemId itemId: String) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: downloadsDirectory, includingPropertiesForKeys: nil
        ) else { return nil }
        return files.first { $0.deletingPathExtension().lastPathComponent == itemId }
    }

    func download(item: LibraryItemDetail, apiClient: APIClient) async {
        guard !isDownloaded(itemId: item.id), !isDownloading(itemId: item.id) else { return }
        guard let track = item.media.tracks?.first,
              let remoteURL = apiClient.streamURL(forContentPath: track.contentUrl) else {
            errorMessage = "Kein herunterladbarer Track gefunden."
            return
        }

        var request = URLRequest(url: remoteURL)
        if let token = apiClient.token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        downloadProgress[item.id] = 0
        let itemId = item.id

        let downloader = FileDownloader { fraction in
            Task { @MainActor in
                DownloadManager.shared.downloadProgress[itemId] = fraction
            }
        }

        do {
            let tempURL = try await downloader.download(request: request)
            let ext = remoteURL.pathExtension.isEmpty ? "m4b" : remoteURL.pathExtension
            let destination = downloadsDirectory.appendingPathComponent("\(itemId).\(ext)")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)

            // Von iCloud-/Geräte-Backups ausschließen — Hörbücher sind groß
            // und gehören nicht ins iPhone-Backup.
            var destinationVar = destination
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try? destinationVar.setResourceValues(resourceValues)

            downloadedItemIds.insert(itemId)
            downloadProgress[itemId] = nil
        } catch {
            errorMessage = "Download fehlgeschlagen: \(error.localizedDescription)"
            downloadProgress[itemId] = nil
        }
    }

    func deleteDownload(itemId: String) {
        guard let url = localFileURL(forItemId: itemId) else { return }
        try? FileManager.default.removeItem(at: url)
        downloadedItemIds.remove(itemId)
    }
}
