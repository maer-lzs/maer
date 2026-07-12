import ActivityKit
import Foundation

/// Describes the running playback for Live Activity / Dynamic Island —
/// deliberately a slim addition to Apple's system "Now Playing" (which already
/// provides cover, scrubber, transport): chapter name + chapter countdown, and
/// during a sleep timer its countdown (moon).
/// This file belongs to BOTH targets (app + widget extension) — it is the
/// shared contract between app and lock-screen UI.
/// nonisolated: the Codable conformance must be usable from the nonisolated
/// ActivityKit context (project default is MainActor).
nonisolated struct PlaybackActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Render base for `Text(timerInterval:)` in the widget.
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
