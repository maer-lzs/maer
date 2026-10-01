// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog
import Combine

/// Carries the feed credentials over the Mär sync service, sealed.
///
/// **There is deliberately no carrier seam here**, unlike the pot, the
/// claim, the statistics, the playlists and the choices. Those have three
/// transports and therefore a protocol. This class has exactly one and will
/// never have a second: the whole point of it is that these credentials stop
/// travelling through Apple, so a second carrier would be the thing being
/// removed. A protocol with one conformance would be a fence around nothing.
///
/// What it does on every round: read every device's sealed block, open the
/// ones this device's code opens, merge them with what is held here, write
/// the merged state back into the keychain, and put this device's own block
/// up if it differs. What it never does is decide anything about feeds; that
/// lives in `FeedAuthMerge` and `FeedAuthStanding`, pure.
@MainActor
final class FeedAuthSync: ObservableObject {
    static let shared = AccessFollowers.enrolled(FeedAuthSync())

    private var session: MaerSyncSession?
    private(set) var started = false
    /// Rounds that ran past the switch since the start, for the witness that
    /// the runner really runs: a runner nobody starts counts none, and a
    /// runner under a switch that is off counts none either.
    private(set) var rounds = 0
    /// The ONE switch, asked at the start AND on every round, like the six
    /// other runners ask it: read once at the start it held the runner on
    /// (off → on after the start never started it, on → off after the start
    /// kept it writing, because the session's own gate is the access).
    private let syncEnabled: () -> Bool

    /// What the page shows, recomputed on every round; published, so the
    /// page observes the runner instead of mirroring one reading of it.
    @Published private(set) var block: FeedAuthStanding.Block = .none

    /// Where the runner reads its keys and the credentials, and where it
    /// writes them back. The device's keychain in the app (`device`); a
    /// witness with two devices against one service hands in two of its own.
    struct Keys {
        var code: () -> String?
        var forgetCode: () -> Void
        var feed: (URL) -> Data?
        var mine: () -> [String: FeedAuthBlock.Entry]?
        var apply: (_ merged: [String: FeedAuthBlock.Entry], _ mine: [String: FeedAuthBlock.Entry]) -> Void

        static let device = Keys(
            code: { DeviceLinkCodeStore.current() },
            forgetCode: { DeviceLinkCodeStore.forget() },
            feed: { FeedKeyStore.held(for: $0) },
            mine: { PodcastFeedAuth.all() },
            apply: { PodcastFeedAuth.apply($0, mine: $1) })
    }
    private let keys: Keys
    /// The envelope of the last block this runner put up, so the code is
    /// forgotten only after a block sealed with the feed key went out.
    private var lastPutUp: Int?

    init(syncEnabled: @escaping () -> Bool = { AppStorageKeys.syncAcrossDevicesEnabled },
         keys: Keys = .device) {
        self.syncEnabled = syncEnabled
        self.keys = keys
    }

    /// The start from the housekeeping and from the switch, beside the
    /// other six runners and under their switch. The session knows whether
    /// there is an access to run on; without one the runner gets no session
    /// and does nothing (invariant 4 below). Measured before this existed:
    /// nobody started the runner, so no device ever put a block up or read
    /// one, and the page showed a code that carried nothing.
    func startIfConfigured(session: MaerSyncSession = MaerSyncCarriers.session, by caller: String) {
        guard syncEnabled() else { return }
        start(session: session.access == nil ? nil : session, by: caller)
    }

    /// Starts carrying, if there is a service to carry over. A second start
    /// nudges a round instead of doing nothing, like the six others: the
    /// switch turned on again is such a second start.
    ///
    /// Without a service this does nothing at all, which is invariant 4: with
    /// iCloud and no service everything stays exactly as it was before any of
    /// this existed.
    func start(session: MaerSyncSession?, by caller: String) {
        guard let session else { return }
        guard !started else { reconcile(by: caller); return }
        started = true
        self.session = session
        session.feedAuthFamily.onChange = { [weak self] in self?.reconcile(by: "change") }
        // Whether this device seals with the account's key or still with its
        // code; no value, only the fact.
        let held = session.access.flatMap { keys.feed($0.baseURL) } != nil
        Logger.library.notice("FEEDKEY held=\(held ? "yes" : "no", privacy: .public)")
        session.start()
        reconcile(by: caller)
    }

    /// A local edit happened: put it up.
    @discardableResult
    func noteLocalChange(by caller: String) -> FeedAuthStanding.Block {
        guard started else { return block }
        reconcile(by: caller)
        // The new standing comes back with the action instead of being
        // fetched afterwards. A caller that had to ask again would be two
        // reaches for one question, and the second one could see a state
        // from between two rounds.
        return block
    }

    private func reconcile(by caller: String) {
        let signpost = PerfSignpost.syncRound(.feedAuth, .maerSync)
        defer { signpost.end() }
        // The switch is asked on every round, not only at the start: off
        // means nothing travels, and the session's own gate (an access)
        // would let this runner write on after the person said no.
        guard syncEnabled() else {
            Logger.library.notice("FEEDAUTH switch off, round skipped by=\(caller, privacy: .public)")
            return
        }
        rounds += 1
        guard let session else { return }
        // The account's feed key when this device signed in with the
        // password; the device code only where there is no feed key yet.
        let feed = session.access.flatMap { keys.feed($0.baseURL) }
        var code = keys.code()
        // Once the own block sealed with the feed key stands, the code has
        // nothing left to open for this device, and it goes.
        if FeedAuthRound.mayForgetCode(hasFeed: feed != nil, hasCode: code != nil,
                                       ownFeedBlockStands: lastPutUp == FeedAuthRound.feedEnvelope
                                           && session.feedAuthOwnBlockStands) {
            keys.forgetCode()
            code = nil
            Logger.library.notice("FEEDAUTH code forgotten: the own block sealed with the feed key stands")
        }
        guard feed != nil || code != nil else { return }
        // A keychain that could not be listed is NOT an empty keychain. The
        // difference decides whether this device may contribute at all: an
        // empty reading would put up a block that says "no credentials" and
        // the other devices would merge that silence with their own.
        guard let mine = keys.mine() else {
            Logger.library.notice("FEEDAUTH keychain not listable, round skipped by=\(caller, privacy: .public)")
            return
        }
        let own = session.ownDeviceId
        var openings: [FeedAuthBlock.Opening] = []
        var theirs: [[String: FeedAuthBlock.Entry]] = []
        for (device, body) in session.feedAuthBodies where device != own {
            let opening = FeedAuthCrypto.open(body, code: code, feed: feed)
            guard FeedAuthRound.counts(envelope: FeedAuthCrypto.version(of: body), opening: opening,
                                       hasFeed: feed != nil) else { continue }
            openings.append(opening)
            guard case .plaintext(let plain) = opening,
                  case .entries(let entries) = FeedAuthBlock.decode(plain) else { continue }
            theirs.append(entries)
        }

        // Everything that could lose a credential is decided in there, pure.
        let plan = FeedAuthRound.plan(mine: mine, theirs: theirs, openings: openings,
                                      listed: session.feedAuthListed)
        block = plan.block
        if let apply = plan.apply {
            keys.apply(apply, mine)
            // Another device's credentials arrived or changed: feeds that
            // waited for a sign-in get one fresh attempt.
            if FeedAuthRound.accessArrived(apply: apply, mine: mine) {
                NotificationCenter.default.post(name: FeedAdoptionPending.accessArrived, object: nil,
                                                userInfo: ["by": "feed access arrived"])
            }
        }
        guard let putUp = plan.putUp else {
            let reason = plan.hold?.logReason ?? "-"
            Logger.library.notice("FEEDAUTH holding back, \(reason, privacy: .public) by=\(caller, privacy: .public)")
            return
        }
        let envelope = FeedAuthRound.writes(hasFeed: feed != nil)
        // What stands for this device already, opened with the same keys.
        // A round whose block would say the same writes nothing: a fresh
        // seal of the same content is new bytes, and the other device
        // answered every new version with one of its own (build 42).
        let ownBody = session.feedAuthBodies[own]
        var standing: [String: FeedAuthBlock.Entry]?
        if let ownBody, case .plaintext(let plain) = FeedAuthCrypto.open(ownBody, code: code, feed: feed),
           case .entries(let entries) = FeedAuthBlock.decode(plain) {
            standing = entries
        }
        guard FeedAuthRound.mustPutUp(putUp, envelope: envelope, standing: standing,
                                      standingEnvelope: ownBody.flatMap(FeedAuthCrypto.version(of:))) else {
            // The block of this envelope stands, so the code may go as if
            // this round had written it.
            lastPutUp = envelope
            // Said, so a round that held back is told apart from no round:
            // on the device, the silence alone proved neither.
            Logger.library.notice("FEEDAUTH unchanged, nothing put up envelope=\(envelope) by=\(caller, privacy: .public)")
            return
        }
        let plain = FeedAuthBlock.encode(putUp)
        let sealed: Data?
        if let feed {
            sealed = plain.flatMap { FeedAuthCrypto.seal($0, feed: feed) }
        } else {
            sealed = both(plain, code).flatMap { FeedAuthCrypto.seal($0, code: $1) }
        }
        guard let sealed else {
            Logger.library.error("FEEDAUTH could not seal by=\(caller, privacy: .public)")
            return
        }
        // Counting entries, never naming one: the log says how much travels
        // and nothing about whose feed it is.
        Logger.library.log("FEEDAUTH put up entries=\(putUp.count) envelope=\(envelope) by=\(caller, privacy: .public)")
        session.writeFeedAuth(sealed, deviceId: own, by: caller)
        lastPutUp = envelope
    }
}

/// Both optionals, or nil when either is missing.
private func both<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}

extension FeedAuthSync: AccessFollower {
    var followerName: String { "feed access" }

    /// The runner rides the session, which reads the access itself; a runner
    /// that found no access at its start starts now. Signing out needs
    /// nothing here: every round of the session ends at its missing access.
    func followAccess(signedIn: Bool, by caller: String) {
        guard signedIn else { return }
        startIfConfigured(by: caller)
    }
}
