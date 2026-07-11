import ActivityKit
import Foundation

/// Beschreibt die laufende Wiedergabe für Live Activity / Dynamic Island —
/// bewusst als schmale ERGÄNZUNG zu Apples System-„Now Playing" (das Cover,
/// Scrubber und Transport bereits liefert): Kapitelname + Kapitel-Countdown,
/// und während eines Schlaf-Timers dessen Countdown (Mond).
/// Diese Datei gehört in BEIDE Targets (App + Widget-Extension) — sie ist
/// der gemeinsame Vertrag zwischen App und Lock-Screen-UI.
/// nonisolated: die Codable-Konformanz muss aus dem nonisolated
/// ActivityKit-Kontext nutzbar sein (Projekt-Default ist MainActor).
nonisolated struct PlaybackActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Render-Basis für `Text(timerInterval:)` im Widget.
        var capturedAt: Date
        var isPlaying: Bool
        var chapterName: String?
        /// Wall-clock end of the current chapter at the current speed —
        /// nil for chapterless books. Freezes in the widget while paused
        /// (position-based by nature).
        var chapterEndDate: Date?
        /// Wall-clock end of a RUNNING sleep timer, nil without one.
        /// EVERY timer freezes while paused (the app only counts during
        /// playback) — the widget shows a live countdown only while playing.
        var sleepEndDate: Date?
    }

    var bookTitle: String
    var author: String?
    var itemId: String
}
