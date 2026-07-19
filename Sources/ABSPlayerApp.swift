import SwiftUI
import UIKit
import CarPlay

/// Central types/signals for "resume" from outside (home-screen quick action,
/// Siri shortcut): both only set a pending flag + notification; the library
/// (owner of list + coordinator) carries it out.
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

/// Background download events + scene configuration (quick actions need their
/// own scene delegate with the SwiftUI lifecycle).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Register BGTask handler — must happen before launch finishes.
        PodcastRefreshService.registerBackgroundTask()
        return true
    }

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
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        // UI-test harness only (compiles out of Release, no-op without -uitest):
        // bypass login + seed deterministic content BEFORE the first render.
        UITestSeed.applyIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // App-wide accent color: orange instead of system blue.
                .tint(AppTheme.accent)
                .preferredColorScheme(preferredScheme)
                // On moving to the background, schedule the next podcast refresh.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { PodcastRefreshService.schedule() }
                    // Y34: migrate legacy keychain items while the device is
                    // certainly unlocked (one-time, self-retrying).
                    if phase == .active { KeychainStore.migrateAccessibilityOnce() }
                }
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

/// Central place for app-wide colors. To change the accent color, adjust it
/// here.
enum AppTheme {
    #if DEBUG
    /// Teil 7 (decision prep only): DEBUG-only brand-accent trial so the
    /// candidates can be compared live on device — 0 = orange (today),
    /// 1 = Mär blue candidate, 2 = anthracite candidate. The productive value
    /// stays orange until the brand decision; the selector tab tints are
    /// untouched either way.
    static var accent: Color {
        switch UserDefaults.standard.integer(forKey: "brandAccentTrial") {
        case 1: return maerBlue
        case 2: return anthracite
        default: return .orange
        }
    }
    static let maerBlue = Color(red: 0.20, green: 0.36, blue: 0.66)
    static let anthracite = Color(red: 0.24, green: 0.26, blue: 0.29)
    #else
    static let accent = Color.orange
    #endif
}
