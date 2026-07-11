import AppIntents
import Foundation

/// "Weiterhören": öffnet die App und setzt das zuletzt gehörte Buch fort —
/// derselbe Pfad wie die Home-Screen-Quick-Action (Pending-Flag +
/// Notification, ausgeführt von der Bibliothek).
struct ContinueListeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Listening"
    static let description = IntentDescription("Resumes the last played audiobook.")
    /// Robusteste Variante: App in den Vordergrund holen und dort starten
    /// (Audio-Start aus dem Hintergrund wäre fehleranfälliger).
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ResumeRequest.pending = true
        NotificationCenter.default.post(name: .resumeLastBookRequested, object: nil)
        return .result()
    }
}

struct HoerregalShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ContinueListeningIntent(),
            phrases: [
                "Continue listening in \(.applicationName)",
                "Resume my audiobook in \(.applicationName)",
                "Weiterhören in \(.applicationName)",
                "Höre mein Hörbuch in \(.applicationName) weiter"
            ],
            shortTitle: "Continue Listening",
            systemImageName: "play.fill"
        )
    }
}
