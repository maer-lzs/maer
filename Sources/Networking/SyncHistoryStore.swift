import Foundation
import Combine
import OSLog

/// F9: narrow storage seam for the sync history — stage 2 (iCloud mirror) and
/// the Android long-term goal swap the implementation behind this protocol;
/// neither is built now.
@MainActor
protocol SyncHistoryStoring: AnyObject {
    var entries: [SyncHistoryEntry] { get }
    func append(_ entry: SyncHistoryEntry)
}

/// Local JSON ring buffer (last 50 runs) in the Documents directory.
@MainActor
final class SyncHistoryStore: ObservableObject, SyncHistoryStoring {
    static let shared = SyncHistoryStore()

    @Published private(set) var entries: [SyncHistoryEntry] = []

    private let fileURL: URL

    /// Injectable file location for tests.
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("syncHistory.json")
        // Y36 (Regel 3): a failed load must never be silent — a corrupt file
        // would drop the whole history and the next append would overwrite it.
        if FileManager.default.fileExists(atPath: self.fileURL.path) {
            do {
                let data = try Data(contentsOf: self.fileURL)
                entries = SyncHistory.trimmed(try JSONDecoder().decode([SyncHistoryEntry].self, from: data))
                Logger.library.notice("sync history loaded: \(self.entries.count) entries")
            } catch {
                Logger.library.error("sync history load FAILED: \(error.localizedDescription, privacy: .public)")
                // Park the unreadable file as evidence — otherwise the next
                // append would silently overwrite it with a fresh ring.
                let parked = self.fileURL.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: parked)
                try? FileManager.default.moveItem(at: self.fileURL, to: parked)
            }
        }
    }

    func append(_ entry: SyncHistoryEntry) {
        entries = SyncHistory.trimmed([entry] + entries)
        Logger.library.notice("sync history append: \(entry.service.rawValue, privacy: .public) → \(self.entries.count) entries")
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // The in-memory list still shows the run; only persistence failed.
            Logger.library.error("sync history write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stable per-install device id (persistent random UUID — portable to
    /// non-Apple platforms, unlike identifierForVendor).
    static var deviceId: String {
        if let existing = UserDefaults.standard.string(forKey: "syncHistoryDeviceId") {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: "syncHistoryDeviceId")
        return fresh
    }
}
