import Foundation

/// App Group — gemeinsamer Container von App und Widget-Extension.
/// Forks: an die eigene Bundle-Struktur anpassen (zusätzlich in den
/// .entitlements-Dateien BEIDER Targets ändern).
nonisolated enum AppGroup {
    static let identifier = "group.de.lzs.ABSPlayer"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

/// Zuletzt gehörtes Buch fürs Home-Screen-Widget: die App schreibt (siehe
/// PlayerViewModel+Widget), das Widget liest — eigener Prozess, deshalb
/// über den App-Group-Container. Datei gehört BEIDEN Targets.
nonisolated struct WidgetSnapshot: Codable {
    var itemId: String
    var title: String
    var author: String?
    /// 0…1 Buchfortschritt zum Schreibzeitpunkt.
    var fraction: Double
    var remainingText: String?
    var isPlaying: Bool

    static var snapshotURL: URL? {
        AppGroup.containerURL?.appendingPathComponent("widget-snapshot.json")
    }
    /// Cover-Thumbnail als PNG neben dem Snapshot.
    static var coverURL: URL? {
        AppGroup.containerURL?.appendingPathComponent("widget-cover.png")
    }

    static func load() -> WidgetSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        guard let url = Self.snapshotURL, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
