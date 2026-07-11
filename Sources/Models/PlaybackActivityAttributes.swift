import ActivityKit
import Foundation

/// Beschreibt die laufende Wiedergabe für Live Activity / Dynamic Island.
/// Diese Datei gehört in BEIDE Targets (App + Widget-Extension) — sie ist
/// der gemeinsame Vertrag zwischen App und Lock-Screen-UI.
/// nonisolated: die Codable-Konformanz muss aus dem nonisolated
/// ActivityKit-Kontext nutzbar sein (Projekt-Default ist MainActor).
nonisolated struct PlaybackActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var chapterName: String?
        var isPlaying: Bool
        /// Absolute Buchposition/-dauer (Sekunden) zum Update-Zeitpunkt.
        var currentTime: Double
        var duration: Double
        /// Wall-clock moment `currentTime` was captured — the widget
        /// extrapolates from it instead of needing constant updates.
        var capturedAt: Date
    }

    var bookTitle: String
    var author: String?
    var itemId: String
}
