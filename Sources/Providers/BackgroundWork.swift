// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import UIKit

/// Time to finish a piece of work after the app leaves the screen.
///
/// iOS grants a short while and then says it is over; the work has to stop
/// at a point where what is done stays done. The seam exists so a witness
/// can say "over" at a moment of its choosing: without it, the stop path
/// could only be seen on a device, backgrounded at the right second.
@MainActor
protocol BackgroundWork: AnyObject {
    /// Asks for time. `expired` runs on the main actor when iOS ends it;
    /// the time is given back by then.
    func begin(_ name: String, expired: @escaping @MainActor () -> Void) -> BackgroundWorkToken
    /// Gives the time back once the work is done.
    func end(_ token: BackgroundWorkToken)
}

struct BackgroundWorkToken: Equatable, Sendable {
    let raw: Int
}

/// The system's background time, through `UIApplication`.
@MainActor
final class SystemBackgroundWork: BackgroundWork {
    static let app = SystemBackgroundWork()

    /// Time still held; an expiry gives its own back, and a later `end`
    /// must not give it back a second time.
    private var live: Set<Int> = []
    private let application = UIApplication.shared

    func begin(_ name: String, expired: @escaping @MainActor () -> Void) -> BackgroundWorkToken {
        let application = self.application
        let identifier = Box()
        identifier.value = application.beginBackgroundTask(withName: name) { [weak self] in
            // iOS calls this on the main thread and wants the time back
            // before it returns.
            MainActor.assumeIsolated {
                expired()
                self?.live.remove(identifier.value.rawValue)
                application.endBackgroundTask(identifier.value)
            }
        }
        if identifier.value != .invalid { live.insert(identifier.value.rawValue) }
        return BackgroundWorkToken(raw: identifier.value.rawValue)
    }

    func end(_ token: BackgroundWorkToken) {
        guard live.remove(token.raw) != nil else { return }
        application.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token.raw))
    }

    /// The identifier, reachable from the expiry handler that is built
    /// before the identifier exists.
    private final class Box {
        var value: UIBackgroundTaskIdentifier = .invalid
    }
}
