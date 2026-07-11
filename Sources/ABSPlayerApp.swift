import SwiftUI
import UIKit

/// Nur für Background-Download-Events: iOS weckt die App, wenn Downloads der
/// Background-Session fertig sind (auch nach System-Kill) — der Handler muss
/// gespeichert und nach Verarbeitung aller Events aufgerufen werden.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        FileDownloader.shared.backgroundCompletionHandler = completionHandler
    }
}

@main
struct ABSPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppStorageKeys.appearance) private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            RootView()
                // Globale Akzentfarbe der App: Orange statt System-Blau.
                .tint(AppTheme.accent)
                .preferredColorScheme(preferredScheme)
        }
    }

    /// Settings override for the appearance; nil = follow the system.
    private var preferredScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}

/// Zentrale Stelle für App-weite Farben. Wenn du die Akzentfarbe ändern
/// willst, reicht es, sie hier anzupassen.
enum AppTheme {
    static let accent = Color.orange
}
