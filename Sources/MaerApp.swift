// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import UIKit
import CarPlay
import CloudKit
import OSLog

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

/// Same shape for "open what the message was about": the tap only leaves a
/// pending target + a signal, the library carries it out. One mechanism for
/// every outside trigger. Quick action, Siri, widget, notification.
@MainActor
enum PodcastOpenRequest {
    /// The key the message carries its show under. It travels in `userInfo`,
    /// which is untyped. So it is read in exactly one place and as a String.
    /// `nonisolated` because the tap is delivered off the main actor and reads
    /// it there; the pending target below stays main-actor state.
    nonisolated static let feedKey = "maerPodcastFeedURL"
    static var pending: NewEpisodeDigest.Target?
}

extension Notification.Name {
    static let resumeLastBookRequested = Notification.Name("resumeLastBookRequested")
    static let podcastNewEpisodesTapped = Notification.Name("podcastNewEpisodesTapped")
}

/// Background download events + scene configuration (quick actions need their
/// own scene delegate with the SwiftUI lifecycle).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // The first line of every process names the code it runs. An
        // installation is not the running stand: a device once kept the
        // old process alive across an install, and every log line after
        // it belonged to code that was no longer on the device.
        let info = Bundle.main.infoDictionary ?? [:]
        Logger.library.notice("APP start version=\(info["CFBundleShortVersionString"] as? String ?? "?", privacy: .public) build=\(info["CFBundleVersion"] as? String ?? "?", privacy: .public) sha=\(info["GitSHA"] as? String ?? "?", privacy: .public)")
        // Register BGTask handler. Must happen before launch finishes.
        PodcastRefreshService.registerBackgroundTask()
        // Silent pushes need a registered device; the ones we ask for
        // carry no alert, so this asks nobody for permission.
        application.registerForRemoteNotifications()
        // Without a delegate a tap is delivered nowhere: the app opens
        // wherever it was left. Assigned here because a launch FROM a tap
        // delivers the response right after this call.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        FileDownloader.shared.backgroundCompletionHandler = completionHandler
    }

    /// A silent push from one of the CloudKit zones. It carries NOTHING but
    /// the zone: the fetch by token brings what changed, and the register
    /// asks the carrier of that zone (every carrier when the zone is
    /// missing). An accelerator, not a promise: measured on 06.09.2026
    /// nothing arrived while the device was locked and idle, so the
    /// ten-second poll while playing stays the way a takeover reaches the
    /// other device; on 14.09.2026 a takeover reached a locked, playing
    /// device in about a second, the deliverer unmeasured.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        let zone = (CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKRecordZoneNotification)?
            .recordZoneID?.zoneName
        await CarrierRefreshers.refresh(zone: zone, by: "push")
        return .newData
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        // Two scene roles: the CarPlay template scene gets its own delegate,
        // everything else stays the SwiftUI window scene (quick actions).
        // The car config is resolved BY NAME from Info.plist. Assigning
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

/// The tap on a new-episode message.
///
/// `nonisolated` by the same contract as the background-task handler: the
/// system calls this off the main queue, and under the project's MainActor
/// default an implicitly isolated conformance would trap at exactly the moment
/// nobody tests. The first real tap. The untyped payload is read HERE and only
/// a String crosses the hop.
extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let feedURL = response.notification.request.content
            .userInfo[PodcastOpenRequest.feedKey] as? String
        Task { @MainActor in
            PodcastOpenRequest.pending = feedURL.map { .show(feedURL: $0) } ?? .latestEpisodes
            NotificationCenter.default.post(name: .podcastNewEpisodesTapped, object: nil)
        }
        completionHandler()
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
struct MaerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        // UI-test harness only (compiles out of Release, no-op without -uitest):
        // bypass login + seed deterministic content BEFORE the first render.
        UITestSeed.applyIfRequested()
        UITestSeed.applySetupProbeIfRequested()
        FrameProbe.shared.startIfRequested()
        #endif
        // Clear orphaned import temp (partial downloads/upload
        // bodies of a killed import). No invisible MB; freed size in the log.
        LibriVoxImporter.sweepOrphanTemp()
        // Row switches that one key used to share start from the old
        // choice, before the first render reads them.
        AppRows.carryOldChoices()
        // The listening stock and its tables: installs the synchronous read of
        // the tables and loads the stock from them (from the old keys once, on
        // the first start of the move), so every write from here on lands in
        // the rows. The writes, the move and the retirement of the old keys
        // run on the mirror's own chain, off the start path.
        StandMirror.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // App-wide accent color: the dark-gray brand accent
                // instead of system blue.
                .tint(AppTheme.accent)
                // Switches are the ONE control the brand accent may
                // not colour. Measured: the grey is not set anywhere. It IS
                // the accent (anthracite), inherited by every one of the
                // app's toggles, none of which tints itself. On a switch that
                // costs the state its readability: "on" and "off" differ by a
                // brightness nuance and the knob position, and a state
                // indicator you have to search for is not one.
                //
                // A capsule shows a CHOICE among visible alternatives. There
                // the accent works, because the alternatives calibrate it. A
                // switch shows a two-valued state with nothing to compare it
                // to. Different jobs, different means; that is why this stops
                // at toggles and the tab capsules keep the accent.
                //
                //
                // Deliberately NOT solved here: both root-level routes (a
                // `.toggleStyle` on this view, the UISwitch appearance proxy)
                // were built and MEASURED not to arrive. The settings sheet is
                // its own presentation host. The switch colour lives in the
                // shared `AppSwitch` building block instead, with a source
                // fence that no bare `Toggle` slips back in.
                //
                // The appearance itself takes the same lesson: the root and
                // every presented leaf carry the ONE building block, because
                // a presentation host does not inherit the preference.
                .followsAppearanceChoice()
                // On moving to the background, schedule the next podcast refresh.
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                    Self.settleRows()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        PodcastRefreshService.schedule()
                        Self.settleRows()
                    }
                }
        }
    }

    /// The app's two ends (going to background, terminating), one door. The
    /// totals write at most every 30 s, and a swiped-away or system-killed
    /// app never reaches pause or stop, so their counted seconds go to their
    /// chain first; playback itself continues in the background. Then every
    /// row chain lands, and the rows' journal is written back into the file:
    /// iOS ends the app without a clean close, and a copy of the file alone
    /// would lose the journal.
    @MainActor
    private static func settleRows() {
        ListeningStatsStore.shared.flush()
        Task {
            await RowKeepers.awaitAll()
            await MaerDatabase.shared.checkpoint()
        }
    }

}

/// Central place for app-wide colors. To change the accent color, adjust it
/// here.
enum AppTheme {
    typealias RGB = (r: Double, g: Double, b: Double)
    /// One gray candidate: a light-scheme tone and a dark-scheme tone. The
    /// accent MUST be adaptive. A fixed dark gray would vanish on the
    /// always-dark player/hero surfaces.
    typealias GrayShade = (light: RGB, dark: RGB)

    /// The accent is DARK GRAY/anthracite (a brand decision). Orange
    /// lives on ONLY as the audiobook TYPE color at the tab selector
    /// (`MediaType.tint`). Adaptive by design (a fixed dark gray would vanish
    /// on the always-dark player/hero surfaces); the tone is hard-set after the
    /// on-device trial.
    private static let currentShade: GrayShade = ((0.24, 0.26, 0.29), (0.78, 0.80, 0.83))

    static var accent: Color { Color(accentUIColor) }

    /// The ON colour of every switch. The system green, not the brand
    /// accent. A switch has to be readable at a glance, and the anthracite
    /// accent made "on" look like "off": four switches, two states, one
    /// brightness nuance apart.
    static var switchOn: Color { Color(UIColor.systemGreen) }

    /// The accent as a DYNAMIC UIColor. Also for UIKit-backed views (AirPlay
    /// route button): `UIColor(Color)` flattens to one trait at init, this
    /// provider keeps the light/dark adaptation alive.
    static var accentUIColor: UIColor {
        let shade = currentShade
        // @Sendable: UIKit resolves dynamic colors on
        // ARBITRARY threads (SwiftUI's AsyncRenderer included). A closure
        // inheriting the project's MainActor default trips the executor check
        // there and traps. Captures are plain Double tuples.
        return UIColor { @Sendable trait in
            let c = trait.userInterfaceStyle == .dark ? shade.dark : shade.light
            return UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        }
    }
}
