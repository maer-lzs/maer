import SwiftUI
import UIKit
import CarPlay

/// Zentrale Typen/Signale für "Weiterhören" von außen (Home-Screen Quick
/// Action, Siri-Shortcut): beide setzen nur ein Pending-Flag + Notification;
/// die Bibliothek (Besitzerin von Liste + Coordinator) führt aus.
enum ResumeRequest {
    static let quickActionType = "resumeLastBook"
    /// Set by quick action / Siri intent, consumed by the library screen.
    static var pending = false
    /// Specific book requested via Siri ("Play <book>"); takes precedence
    /// over the plain "continue last book" request.
    static var pendingItemId: String?
}

extension Notification.Name {
    static let resumeLastBookRequested = Notification.Name("resumeLastBookRequested")
}

/// Background-Download-Events + Szenen-Konfiguration (Quick Actions brauchen
/// mit SwiftUI-Lifecycle einen eigenen Scene-Delegate).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        FileDownloader.shared.backgroundCompletionHandler = completionHandler
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        // Two scene roles: the CarPlay template scene gets its own delegate,
        // everything else stays the SwiftUI window scene (quick actions).
        // The car config is resolved BY NAME from Info.plist — assigning
        // sceneClass/delegateClass here in code gets overridden by SwiftUI's
        // own scene delegate, which crashes on CarPlay connect.
        if connectingSceneSession.role == .carTemplateApplication {
            return UISceneConfiguration(name: "CarPlay", sessionRole: connectingSceneSession.role)
        }
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Cold start via quick action: the shortcut arrives in the connection
    /// options, not via performActionFor.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if connectionOptions.shortcutItem?.type == ResumeRequest.quickActionType {
            ResumeRequest.pending = true
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        if shortcutItem.type == ResumeRequest.quickActionType {
            ResumeRequest.pending = true
            NotificationCenter.default.post(name: .resumeLastBookRequested, object: nil)
        }
        completionHandler(true)
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
