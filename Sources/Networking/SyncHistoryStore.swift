import Foundation
import Combine

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
        if let data = try? Data(contentsOf: self.fileURL),
           let stored = try? JSONDecoder().decode([SyncHistoryEntry].self, from: data) {
            entries = SyncHistory.trimmed(stored)
        }
    }

    func append(_ entry: SyncHistoryEntry) {
        entries = SyncHistory.trimmed([entry] + entries)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
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
