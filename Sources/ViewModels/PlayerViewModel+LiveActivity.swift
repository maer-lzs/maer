import ActivityKit
import Foundation

/// Live Activity (Lock Screen / Dynamic Island): gestartet beim Abspielen,
/// aktualisiert bei Play/Pause, Seeks und Kapitelwechseln (alles seltene
/// Ereignisse — der Fortschritt selbst wird im Widget aus `capturedAt`
/// extrapoliert, ohne Dauer-Updates), beendet bei Stop/Buchende.
/// Sichtbar wird sie erst, wenn das Widget-Extension-Target existiert —
/// die App-Seite hier funktioniert auch ohne.
extension PlayerViewModel {

    func updateLiveActivity() {
        guard let item, duration > 0 else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let state = PlaybackActivityAttributes.ContentState(
            chapterName: currentChapter?.title,
            isPlaying: isPlaying,
            currentTime: currentTime,
            duration: duration,
            capturedAt: Date()
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

    func endLiveActivity() {
        guard let activity = liveActivity else { return }
        liveActivity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
