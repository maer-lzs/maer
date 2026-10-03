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
    /// `identityChanged`: signed in before and now, but with another
    /// account; the runner starts again as on a change of way.
    func followAccess(signedIn: Bool, identityChanged: Bool, by caller: String)
}

extension AccessFollower {
    /// A change of way alone, the account staying what it was.
    func followAccess(signedIn: Bool, by caller: String) {
        followAccess(signedIn: signedIn, identityChanged: false, by: caller)
    }
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
    /// The app's register; the account it follows is the session's.
    private static let register = AccessRegister(identity: { MaerSyncCarriers.session.identity?.scope })

    /// Enrolls a shared runner as it is built and hands it back.
    static func enrolled<Follower: AccessFollower>(_ follower: Follower) -> Follower {
        register.enroll(follower)
    }

    /// The names of the enrolled runners, for the witness.
    static var names: [String] { register.names }

    /// Every enrolled runner follows the access of this moment. Called where
    /// the access is written, after the session read it again.
    static func followAll(by caller: String) {
        register.followAll(by: caller)
    }

    /// An accepted key change names the same account: the runners keep
    /// their carriers, only the remembered identity moves along.
    static func carry(to identity: MaerSyncIdentity) {
        register.carry(to: identity.scope)
    }
}

/// The runners of one process and the account they hold. Which account is
/// signed in has ONE answer, the session's identity; the register only
/// remembers which one its runners took. It takes that when the first
/// runner enrolls, so the first change of account in a process is seen
/// as one: read later, at the first `followAll`, it already named the new
/// account and no runner changed.
@MainActor
final class AccessRegister {
    private struct Entry {
        weak var follower: (any AccessFollower)?
    }
    private var entries: [Entry] = []
    private let identity: () -> String?
    /// The account the enrolled runners hold; unknown before the first
    /// runner enrolled or the first change was followed.
    private var followed: String??

    init(identity: @escaping () -> String?) {
        self.identity = identity
    }

    func enroll<Follower: AccessFollower>(_ follower: Follower) -> Follower {
        entries.removeAll { $0.follower == nil || $0.follower === follower }
        entries.append(Entry(follower: follower))
        if followed == nil { followed = .some(identity()) }
        return follower
    }

    var names: [String] {
        entries.compactMap { $0.follower?.followerName }
    }

    func followAll(by caller: String) {
        entries.removeAll { $0.follower == nil }
        let now = identity()
        let signedIn = now != nil
        let identityChanged = followed.map { CarrierWay.identityChanged(held: $0, now: now) } ?? false
        followed = .some(now)
        Logger.library.notice("MAERSYNC access changed by=\(caller, privacy: .public) signedIn=\(signedIn) identityChanged=\(identityChanged) runners=\(self.names.joined(separator: ","), privacy: .public)")
        for entry in entries {
            entry.follower?.followAccess(signedIn: signedIn, identityChanged: identityChanged, by: caller)
        }
    }

    func carry(to scope: String) {
        followed = .some(scope)
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
    /// sign-in to the same account changes nothing; a sign-in with another
    /// account starts the runner again, so it reads the new account first.
    static func mustChange(holdsService: Bool, signedIn: Bool, identityChanged: Bool = false) -> Bool {
        holdsService != signedIn || (signedIn && identityChanged)
    }

    /// Another account while signed in before and after. The first sign-in
    /// and a sign-out are changes of way, not of account.
    static func identityChanged(held: String?, now: String?) -> Bool {
        guard let held, let now else { return false }
        return held != now
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
