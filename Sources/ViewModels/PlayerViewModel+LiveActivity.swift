import ActivityKit
import Foundation

/// Live Activity (Lock Screen / Dynamic Island) NUR während eines
/// Schlaf-Timers: eine Live Activity hat IMMER auch eine Lock-Screen-
/// Darstellung (island-only bietet Apple nicht an) — während normaler
/// Wiedergabe wäre die redundant zu Apples „Now Playing", das die Insel-
/// Präsenz (Waveform) ohnehin selbst liefert. Der Schlaf-Countdown dagegen
/// ist die eine Information, die Apples Player nicht kennt.
/// Sichtbar erst mit vorhandenem Widget-Extension-Target; die App-Seite
/// hier funktioniert auch ohne.
extension PlayerViewModel {

    /// Aktualisiert eine laufende Aktivität; NEU gestartet wird nur, wenn
    /// gerade ein Schlaf-Timer läuft (Aufruf aus den Timer-Startpfaden).
    func updateLiveActivity() {
        guard let item, duration > 0 else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Ohne Timer keine NEUE Aktivität; eine laufende wird weiter
        // aktualisiert (Play/Pause/Seek), bis der Timer sie beendet.
        guard liveActivity != nil || sleepTimerRemaining != nil else { return }

        let now = Date()
        // Audio-Sekunden → Wall-Clock über die Wiedergabegeschwindigkeit.
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
            sleepEndDate: sleepEnd,
            sleepPositionBased: sleepPositionBased
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

    /// Aktualisiert eine bereits LAUFENDE Aktivität (Pause, Seek, Kapitel-
    /// oder Schlaf-Timer-Wechsel) — startet aber nie eine neue. Neu
    /// gestartet wird nur über play().
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
