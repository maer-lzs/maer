import Foundation
import Combine

/// Verwaltet lokal heruntergeladene Hörbücher. Speichert Audiodateien im
/// App-Dokumentenordner unter "Downloads/{itemId}.{ext}" und die zugehörigen
/// Buchdetails (Kapitel, Dauer …) separat unter "DownloadsMeta/{itemId}.json"
/// — getrennte Ordner, damit die Datei-Suche für die Audiodatei nicht
/// versehentlich die Metadaten-JSON trifft.
///
/// Die Metadaten-Datei ist der Schlüssel für echtes Offline-Hören: ohne sie
/// müsste die App bei jedem Öffnen eines Buchs erst Kapitel/Dauer vom Server
/// nachladen — selbst wenn die Audiodatei längst lokal vorliegt.
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
        makeDirectory(named: "Downloads")
    }

    private var metadataDirectory: URL {
        makeDirectory(named: "DownloadsMeta")
    }

    private func makeDirectory(named name: String) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
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

    /// Zwischengespeicherte Buchdetails (Kapitel, Dauer, Metadaten) für den
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

            // Buchdetails (Kapitel, Dauer) fürs echte Offline-Öffnen
            // mitspeichern — ohne das bräuchte selbst ein heruntergeladenes
            // Buch beim Öffnen noch eine Serveranfrage.
            saveDetail(item)

            downloadedItemIds.insert(itemId)
            downloadProgress[itemId] = nil
        } catch {
            errorMessage = "Download fehlgeschlagen: \(error.localizedDescription)"
            downloadProgress[itemId] = nil
        }
    }

    func deleteDownload(itemId: String) {
        if let url = localFileURL(forItemId: itemId) {
            try? FileManager.default.removeItem(at: url)
        }
        let metaURL = metadataDirectory.appendingPathComponent("\(itemId).json")
        try? FileManager.default.removeItem(at: metaURL)
        downloadedItemIds.remove(itemId)
    }
}
