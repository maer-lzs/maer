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

    /// Per-book download lifecycle for the UI.
    enum DownloadPhase: Equatable {
        case downloading(Double)
        case paused(Double)
        case failed(String)

        var progress: Double? {
            switch self {
            case .downloading(let p), .paused(let p): return p
            case .failed: return nil
            }
        }
    }

    /// Live control state of a running/paused download (in-memory only —
    /// after a relaunch, partial folders are picked up via resume-by-skip).
    private struct DownloadControl {
        var detail: LibraryItemDetail
        var currentTask: URLSessionDownloadTask?
        var pendingPause = false
        var pendingCancel = false
        var resumeData: Data?
    }

    @Published private(set) var downloadedItemIds: Set<String> = []
    /// Phase per book: downloading (weighted progress), paused, or failed.
    @Published private(set) var phase: [String: DownloadPhase] = [:]
    private var controls: [String: DownloadControl] = [:]
    /// Gecacht statt berechnet — die View liest das bei jedem Render; ein
    /// Disk-Scan pro Fortschritts-Tick wäre teuer.
    @Published private(set) var totalDownloadsSize: Int64 = 0

    private init() {
        downloadedItemIds = Set(scanExistingDownloads())
        recalculateTotalSize()
    }

    private func recalculateTotalSize() {
        totalDownloadsSize = downloadedItemIds.reduce(0) { $0 + downloadSize(forItemId: $1) }
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
            .filter { itemId in
                // Meta-Datei wird erst nach vollständigem Download geschrieben —
                // Ordner ohne Meta ist ein Abbruch-Rest: nicht als "fertig"
                // zählen, aber LIEGEN LASSEN (Resume überspringt fertige Tracks).
                let meta = metadataDirectory.appendingPathComponent("\(itemId).json")
                return FileManager.default.fileExists(atPath: meta.path)
            }
    }

    func isDownloaded(itemId: String) -> Bool {
        downloadedItemIds.contains(itemId)
    }

    func isDownloading(itemId: String) -> Bool {
        if case .downloading = phase[itemId] { return true }
        return false
    }

    /// True if an incomplete download folder exists (aborted/failed earlier) —
    /// a new download will only fetch the missing files.
    func hasPartialDownload(itemId: String) -> Bool {
        guard !downloadedItemIds.contains(itemId) else { return false }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: itemDirectory(itemId), includingPropertiesForKeys: nil)) ?? []
        return !files.isEmpty
    }

    /// Pause: cancel the current track transfer, keeping resume data.
    func pauseDownload(itemId: String) {
        guard case .downloading = phase[itemId], var control = controls[itemId] else { return }
        control.pendingPause = true
        controls[itemId] = control
        control.currentTask?.cancel { _ in /* resume data arrives via delegate */ }
    }

    /// Resume a paused download (continues mid-file via resume data).
    func resumeDownload(itemId: String) {
        guard case .paused = phase[itemId],
              let control = controls[itemId],
              let apiClient = resumeAPIClient else { return }
        // Clear the paused phase so the isDownloading guard lets us restart.
        phase[itemId] = nil
        Task { await download(item: control.detail, apiClient: apiClient) }
    }

    /// Abort: stop the transfer, keep completed tracks (a later download
    /// fetches only the missing files), clear the visible state.
    func cancelDownload(itemId: String) {
        guard var control = controls[itemId] else {
            phase[itemId] = nil
            return
        }
        control.pendingCancel = true
        controls[itemId] = control
        if case .paused = phase[itemId] {
            // Nothing in flight — clear state directly.
            controls[itemId] = nil
            phase[itemId] = nil
        } else {
            control.currentTask?.cancel()
        }
    }

    /// Client used for resumes (set on each download start).
    private weak var resumeAPIClient: APIClient?

    /// Alle lokal heruntergeladenen Audiodateien eines Buchs, sortiert nach
    /// Track-Reihenfolge (Dateiname = Track-Index). Wird vom Player bevorzugt
    /// genutzt, um Streaming (und damit Latenz/Datenvolumen) zu vermeiden.
    func localFileURLs(forItemId itemId: String) -> [URL]? {
        // Nur KOMPLETTE Downloads — liegengebliebene Teil-Ordner (Resume-Reste)
        // würden sonst als lokale Quelle mit falscher Track-Zuordnung dienen.
        guard downloadedItemIds.contains(itemId) else { return nil }
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
            phase[item.id] = .failed(String(localized: "No downloadable track found."))
            return
        }

        let itemId = item.id
        resumeAPIClient = apiClient
        // Carry mid-file resume data over from a pause (used once, for the
        // first track that is actually transferred).
        var carriedResumeData = controls[itemId]?.resumeData
        controls[itemId] = DownloadControl(detail: item, resumeData: nil)
        phase[itemId] = .downloading(0)
        let dir = itemDirectory(itemId)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let perTrackWeight = 1.0 / Double(tracks.count)
        var completedFraction: Double = 0

        do {
            for (index, track) in tracks.enumerated() {
                guard let remoteURL = apiClient.streamURL(forContentPath: track.contentUrl) else { continue }
                let ext = remoteURL.pathExtension.isEmpty ? "m4b" : remoteURL.pathExtension
                let destination = dir.appendingPathComponent("\(index).\(ext)")

                // Resume-by-skip: tracks from an earlier attempt are kept.
                if FileManager.default.fileExists(atPath: destination.path) {
                    completedFraction += perTrackWeight
                    phase[itemId] = .downloading(completedFraction)
                    continue
                }

                var request = URLRequest(url: remoteURL)
                if let token = apiClient.token, !token.isEmpty {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }

                let baseProgress = completedFraction
                let resumeData = carriedResumeData
                carriedResumeData = nil
                try await FileDownloader.shared.download(
                    request: request,
                    to: destination,
                    resumeData: resumeData,
                    onProgress: { fraction in
                        Task { @MainActor in
                            if case .downloading = DownloadManager.shared.phase[itemId] {
                                DownloadManager.shared.phase[itemId] = .downloading(baseProgress + fraction * perTrackWeight)
                            }
                        }
                    },
                    onTask: { task in
                        Task { @MainActor in
                            DownloadManager.shared.controls[itemId]?.currentTask = task
                        }
                    }
                )
                controls[itemId]?.currentTask = nil

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

            // Cover persistent sichern — überlebt iOS-Cache-Purges offline.
            await ImageCache.shared.makePersistent(
                itemId: itemId,
                coverURL: apiClient.coverURL(forItemId: itemId)
            )

            downloadedItemIds.insert(itemId)
            phase[itemId] = nil
            controls[itemId] = nil
            recalculateTotalSize()
        } catch let cancelled as DownloadCancelledError {
            let progress = phase[itemId]?.progress ?? 0
            if controls[itemId]?.pendingCancel == true {
                // Abort: clear visible state, keep completed tracks on disk.
                phase[itemId] = nil
                controls[itemId] = nil
            } else {
                // Pause: remember resume data for a mid-file continuation.
                controls[itemId]?.resumeData = cancelled.resumeData
                controls[itemId]?.pendingPause = false
                phase[itemId] = .paused(progress)
            }
        } catch {
            // Keep partial files: the next attempt fetches only missing tracks.
            phase[itemId] = .failed(String(localized: "Download failed: \(error.localizedDescription)"))
            controls[itemId]?.currentTask = nil
        }
    }

    /// Belegter Speicher eines Buchs in Bytes (0, wenn nichts liegt).
    func downloadSize(forItemId itemId: String) -> Int64 {
        let dir = itemDirectory(itemId)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    func deleteAllDownloads() {
        for itemId in downloadedItemIds {
            deleteDownload(itemId: itemId)
        }
    }

    func deleteDownload(itemId: String) {
        try? FileManager.default.removeItem(at: itemDirectory(itemId))
        let metaURL = metadataDirectory.appendingPathComponent("\(itemId).json")
        try? FileManager.default.removeItem(at: metaURL)
        ImageCache.shared.removePersistent(itemId: itemId)
        downloadedItemIds.remove(itemId)
        recalculateTotalSize()
    }
}
