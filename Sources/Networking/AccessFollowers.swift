// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// A runner that holds a carrier chosen from the sync service's access, and
/// takes the carrier of the moment when the access changes.
@MainActor
protocol AccessFollower: AnyObject {
    /// The family's name in the log line of a change.
    var followerName: String { get }
    /// Asks the factory again; a carrier that travels another way than the
    /// held one replaces it, and a runner that runs starts it as at a cold
    /// start. `signedIn` is read once, at the register, so the runners stay
    /// blind to the service and all of them follow the same moment.
    func followAccess(signedIn: Bool, by caller: String)
}

/// The runners built in this process, so a sign-in or a sign-out reaches
/// every one of them while the app runs. Before, each runner chose its
/// carrier once, when it was built, and a family that was in use before the
/// sign-in kept iCloud until the next start (measured on a device: the
/// subscriptions came only after a restart).
///
/// Only the shared runners enroll, where they are built: asking for a
/// runner would build it, and a test's own runner must never be switched to
/// the app's carrier by somebody else's sign-in. Entries are weak.
@MainActor
enum AccessFollowers {
    private struct Entry {
        weak var follower: (any AccessFollower)?
    }
    private static var entries: [Entry] = []

    /// Enrolls a shared runner as it is built and hands it back.
    static func enrolled<Follower: AccessFollower>(_ follower: Follower) -> Follower {
        entries.removeAll { $0.follower == nil || $0.follower === follower }
        entries.append(Entry(follower: follower))
        return follower
    }

    /// The names of the enrolled runners, for the witness.
    static var names: [String] {
        entries.compactMap { $0.follower?.followerName }
    }

    /// Every enrolled runner follows the access of this moment. Called where
    /// the access is written, after the session read it again.
    static func followAll(by caller: String) {
        entries.removeAll { $0.follower == nil }
        let signedIn = MaerSyncAccess.stored() != nil
        Logger.library.notice("MAERSYNC access changed by=\(caller, privacy: .public) signedIn=\(signedIn) runners=\(names.joined(separator: ","), privacy: .public)")
        for entry in entries { entry.follower?.followAccess(signedIn: signedIn, by: caller) }
    }
}

/// Whether a runner holds the service, and whether it must change its
/// carrier for the access of the moment. Pure, so the decision has a witness.
nonisolated enum CarrierWay {
    /// A carrier of the service names itself with the service's stem.
    static func isService(carrierName: String) -> Bool {
        carrierName.hasPrefix(MaerSyncCarriers.carrierNameStem)
    }

    /// Signed in means the service carries; signed out means iCloud or this
    /// device alone. A runner on the right way keeps its carrier, so a second
    /// sign-in to the same service changes nothing.
    static func mustChange(holdsService: Bool, signedIn: Bool) -> Bool {
        holdsService != signedIn
    }
}

/// A runner's carrier and its generation. Every change of carrier opens a
/// new generation, and a callback of an older one does nothing: a round the
/// old carrier still had running when the access changed may come back
/// later and must neither apply what it found nor make the runner write.
@MainActor
struct CarrierGeneration {
    private(set) var current = 0

    /// A new carrier was taken.
    mutating func advance() { current += 1 }

    /// Wraps `body` so it runs only while the generation it was made in is
    /// still the current one.
    func guarded(_ owner: @escaping @MainActor () -> CarrierGeneration?,
                 _ body: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let made = current
        return {
            guard owner()?.current == made else { return }
            body()
        }
    }
}
