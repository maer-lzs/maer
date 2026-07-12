import ActivityKit
import Foundation

/// Live Activity (lock screen / Dynamic Island) ONLY during a sleep timer: a
/// Live Activity ALWAYS also has a lock-screen presentation (Apple offers no
/// island-only) — during normal playback it would be redundant with Apple's
/// "Now Playing", which provides the island presence (waveform) itself anyway.
/// The sleep countdown, by contrast, is the one piece of information Apple's
/// player does not know.
/// Only visible with a present widget extension target; the app side here works
/// without one too.
extension PlayerViewModel {

    /// Updates a running activity; a NEW one is started only when a sleep timer
    /// is currently running (called from the timer start paths).
    func updateLiveActivity() {
        guard let item, duration > 0 else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // No NEW activity without a timer; a running one keeps updating
        // (play/pause/seek) until the timer ends it.
        guard liveActivity != nil || sleepTimerRemaining != nil else { return }

        let now = Date()
        // Audio seconds → wall clock via the playback speed.
        let rate = max(Double(playbackRate), 0.1)
        let chapterEnd = currentChapter.map { chapter in
            now.addingTimeInterval(max(0, chapter.end - currentTime) / rate)
        }
        let sleepPositionBased = sleepUntilChapterEnd || sleepUntilTrackEnd
        let sleepEnd = sleepTimerRemaining.map { remaining in
            now.addingTimeInterval(sleepPositionBased ? remaining / rate : remaining)
        }

        let state = PlaybackActivityAttributes.ContentState(
            capturedAt: now,
            isPlaying: isPlaying,
            chapterName: currentChapter?.title,
            chapterEndDate: chapterEnd,
            sleepEndDate: sleepEnd
        )
        let content = ActivityContent(state: state, staleDate: nil)

        if let liveActivity {
            Task { await liveActivity.update(content) }
            return
        }
        let attributes = PlaybackActivityAttributes(
            bookTitle: item.media.metadata?.title ?? "",
            author: item.media.metadata?.authorName,
            itemId: item.id
        )
        // Request fails e.g. when activities are disabled or the app is in
        // the background — playback must never care.
        liveActivity = try? Activity.request(attributes: attributes, content: content)
    }

    /// Updates an already RUNNING activity (pause, seek, chapter or sleep-timer
    /// change) — but never starts a new one. A new one is started only via play().
    func refreshLiveActivityIfActive() {
        guard liveActivity != nil else { return }
        updateLiveActivity()
    }

    func endLiveActivity() {
        guard let activity = liveActivity else { return }
        liveActivity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
