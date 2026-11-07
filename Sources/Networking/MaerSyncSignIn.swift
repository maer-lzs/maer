// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The sign-in to a Mär sync service. The address is checked for its
/// shape before anything is sent, the service's key is met BEFORE the
/// password goes anywhere, the password is traded for a device token once,
/// and what the person typed is stored only when the service said yes. The
/// view shows the outcome; it decides nothing.
///
/// **The meeting comes first, and it is the point of this file now.** The
/// sign-in is the one moment a person is looking at the screen, so it is
/// the moment a service's key is met and held, and the moment a DIFFERENT
/// key is shown as an event instead of being trusted in a background round
/// nobody watches. A changed key stops the sign-in before the secret is
/// sent: sending it first and asking afterwards would hand the account to
/// whoever answered.
@MainActor
enum MaerSyncSignIn {
    enum Outcome: Equatable {
        /// The access the service granted, and the account name as it
        /// goes into the settings.
        case signedIn(MaerSyncAccess, account: String)
        case missing
        case badAddress
        case refused
        /// A 403 from the proxy: the service answered, but not from this
        /// network. A self-hosted service reachable only over LAN, mesh or
        /// VPN gives this when the device is outside the tunnel, and
        /// "did not answer" would send the person to the wrong end.
        case blockedHere
        case unreachable(String)
        /// iOS refused the plain http address before a byte left the
        /// device (App Transport Security, URLError -1022). The service was
        /// never asked, so "did not answer" would send the person to the
        /// service when the remedy is the address or the app's transport
        /// rule.
        case plainAddressRefused
        /// The service offers a different key than the one this device
        /// holds for that address. Nothing was sent, nothing was stored;
        /// the person decides, with both fingerprints in front of them.
        case keyChanged(held: String, offered: String)
        /// The service is there and has not made its key yet. Its operator
        /// ends this by starting the service once with a key.
        case serviceHasNoKey
        /// The service does not know the key path at all: it is older than
        /// this app. A named case, because "did not answer" would send the
        /// person to their network when the remedy is an update.
        case serviceIsOlder
        /// The service speaks a newer contract than this app. Said before
        /// anything of the password is derived or sent.
        case serviceIsNewer(Int)
        /// The service knows this account's password (not moved yet, or set
        /// by the operator): it must be changed before a sign-in. Nothing
        /// of the password was sent.
        case needsNewPassword
        /// Too many failed attempts; `retryAfter` in seconds when the
        /// service said. Never retried by itself.
        case tooManyAttempts(retryAfter: Int?)
        /// The service asked for a stretching this app does not accept (too
        /// few or too many rounds, a salt of the wrong size). Nothing was sent.
        case unsafeParameters
        /// The new password misses the rule by this many characters.
        /// Checked before anything is asked.
        case newPasswordTooShort(missing: Int)
        /// The new password is the one in force; the service has seen it.
        case newPasswordSameAsCurrent
        /// The new password and its repetition differ.
        case newPasswordRepeatDiffers
        /// This device could not prepare the new password (no randomness
        /// for its salt). Nothing was sent.
        case localFailure
    }

    enum Reach: Equatable {
        case reached
        case badAddress
        /// The same case the sign-in already tells apart: the service
        /// answered with a refusal from outside its network, which is a
        /// different end of the line than a service that says nothing.
        case blockedHere
        case silent
        /// The same refusal the sign-in tells apart: the platform, not the
        /// service, said no, and nothing was asked.
        case plainAddressRefused
    }

    /// Whether a transport error is the platform refusing a plain http
    /// address: App Transport Security answers with URLError -1022 before
    /// any byte leaves the device. Telling that apart from silence matters
    /// because the service was never asked.
    nonisolated static func isPlatformRefusal(_ error: Error) -> Bool {
        (error as? URLError)?.code == .appTransportSecurityRequiresSecureConnection
    }

    /// The outcome of a transport error on the sign-in: the platform's
    /// refusal by its own name, everything else as silence with its reason.
    nonisolated static func outcome(forTransportError error: Error) -> Outcome {
        isPlatformRefusal(error) ? .plainAddressRefused : .unreachable(MaerSyncFailure.reason(of: error))
    }

    /// What a status on the health route means. Pure, so the sentence the
    /// test button shows is decided in one place and can be driven by a
    /// case instead of by a server.
    ///
    /// The rule behind it: an answer that refuses is not silence. A
    /// self-hosted service behind a proxy that only serves LAN, mesh or
    /// VPN gives 403 to a device outside the tunnel, and telling that
    /// person "the service did not answer" sends them to the wrong end,
    /// where they will look at the service instead of at their network.
    nonisolated static func reach(forStatus status: Int?) -> Reach {
        switch status {
        case 200: return .reached
        case 403: return .blockedHere
        default: return .silent
        }
    }

    /// `acceptingKey` is the person's answer to a `keyChanged` event: the
    /// fingerprint they accepted, from the event itself. It is compared with
    /// what the service offers NOW, not taken on trust: a key that changed
    /// between the event and the answer is a new event, because the person
    /// accepted one key and not "whatever comes next".
    ///
    /// Contract version 6: the key, then the salt, then only the proof. An
    /// account the service reports in form `secret` does not sign in at all;
    /// its password reached the service and must be changed first, so the
    /// sign-in stops there and nothing of the password travels.
    static func perform(address: String, owner: String, password: String,
                        acceptingKey: String? = nil,
                        device: String = SyncHistoryStore.deviceIdForSignIn(),
                        transport: any MaerSyncTransport = MaerSyncHTTP()) async -> Outcome {
        let account = owner.trimmingCharacters(in: .whitespaces)
        guard !address.trimmingCharacters(in: .whitespaces).isEmpty, !account.isEmpty, !password.isEmpty else {
            return .missing
        }
        guard let base = MaerSyncPaths.normalized(address) else { return .badAddress }
        if let stop = await meet(base, acceptingKey: acceptingKey, transport: transport) { return stop }
        let salt: MaerSyncSalt
        do {
            salt = try await transport.salt(owner: account, at: base)
        } catch {
            return Self.outcome(forSignInError: error, host: base.host, step: .signInSalt)
        }
        guard salt.form == .proof else {
            Logger.library.notice("MAERSYNC sign-in stopped host=\(base.host ?? "-", privacy: .public) reason=the account needs a new password first; nothing was sent")
            return .needsNewPassword
        }
        let keys: SignInDerivation.Keys
        do {
            keys = try await SignInDerivation.derived(password: password, salt: salt.salt, rounds: salt.rounds,
                                                      purpose: .signin)
        } catch {
            Logger.library.notice("MAERSYNC sign-in stopped host=\(base.host ?? "-", privacy: .public) reason=\(MaerSyncFailure.reason(of: error), privacy: .public)")
            return .unsafeParameters
        }
        do {
            // Only the proof travels. The feed value stays on this device:
            // this password only ever travelled as its proof.
            let token = try await transport.token(owner: account, proof: keys.proofBase64, device: device, at: base)
            FeedKeyStore.keep(keys.feed, for: base)
            Logger.library.notice("MAERSYNC signed in host=\(base.host ?? "-", privacy: .public)")
            return .signedIn(MaerSyncAccess(baseURL: base, token: token), account: account)
        } catch {
            return Self.outcome(forSignInError: error, host: base.host, step: .signInToken)
        }
    }

    /// A new password for an account, and a token for this device.
    ///
    /// Two cases, told apart by the service's own answer on `/v1/salt`:
    /// - **form `secret`**, the service knows the password in force (the
    ///   account has not moved, or its operator set a one-time password):
    ///   that password travels ONCE, as `current.secret`, and never again;
    /// - **form `proof`**, an ordinary change: the password in force travels
    ///   only as its proof.
    ///
    /// The new password travels only as its proof, under a salt this device
    /// picks, and `feed` comes from it alone, never from a password that
    /// reached the service. Its rule is checked before anything is asked.
    static func changePassword(address: String, owner: String, current currentPassword: String,
                               new newPassword: String, repeated: String, acceptingKey: String? = nil,
                               device: String = SyncHistoryStore.deviceIdForSignIn(),
                               transport: any MaerSyncTransport = MaerSyncHTTP(),
                               freshSalt: () -> Data? = SignInDerivation.freshSalt) async -> Outcome {
        let account = owner.trimmingCharacters(in: .whitespaces)
        guard !address.trimmingCharacters(in: .whitespaces).isEmpty, !account.isEmpty,
              !currentPassword.isEmpty, !newPassword.isEmpty else { return .missing }
        switch PasswordRule.check(new: newPassword, repeated: repeated, current: currentPassword) {
        case .repeatDiffers: return .newPasswordRepeatDiffers
        case .tooShort(let missing): return .newPasswordTooShort(missing: missing)
        case .sameAsCurrent: return .newPasswordSameAsCurrent
        case .acceptable: break
        }
        guard let base = MaerSyncPaths.normalized(address) else { return .badAddress }
        if let stop = await meet(base, acceptingKey: acceptingKey, transport: transport) { return stop }
        let salt: MaerSyncSalt
        do {
            salt = try await transport.salt(owner: account, at: base)
        } catch {
            return Self.outcome(forSignInError: error, host: base.host, step: .changeSalt)
        }
        guard let newSalt = freshSalt(), newSalt.count == SignInDerivation.saltBytes else {
            Logger.library.error("MAERSYNC password change stopped host=\(base.host ?? "-", privacy: .public) reason=no randomness for a new salt; nothing was sent")
            return .localFailure
        }
        let current: MaerSyncCurrent
        let fresh: SignInDerivation.Keys
        do {
            switch salt.form {
            case .secret: current = .secret(currentPassword)
            case .proof:
                current = .proof(try await SignInDerivation.derived(password: currentPassword, salt: salt.salt,
                                                                     rounds: salt.rounds, purpose: .current).proofBase64)
            }
            fresh = try await SignInDerivation.derived(password: newPassword, salt: newSalt,
                                                       rounds: SignInDerivation.minimumRounds, purpose: .new)
        } catch {
            Logger.library.notice("MAERSYNC password change stopped host=\(base.host ?? "-", privacy: .public) reason=\(MaerSyncFailure.reason(of: error), privacy: .public)")
            return .unsafeParameters
        }
        do {
            let token = try await transport.changePassword(
                owner: account, device: device, current: current,
                new: MaerSyncNewPassword(proof: fresh.proofBase64, salt: newSalt, rounds: SignInDerivation.minimumRounds),
                at: base)
            FeedKeyStore.keep(fresh.feed, for: base)
            Logger.library.notice("MAERSYNC password changed host=\(base.host ?? "-", privacy: .public) form=\(salt.form.rawValue, privacy: .public)")
            return .signedIn(MaerSyncAccess(baseURL: base, token: token), account: account)
        } catch {
            return Self.outcome(forSignInError: error, host: base.host, step: .change)
        }
    }

    /// The meeting with the service's key, before anything of a password is
    /// derived or sent: a newer contract is said, a changed key stops as an
    /// event, a first key is held. nil when the sign-in may go on.
    private static func meet(_ base: URL, acceptingKey: String?,
                             transport: any MaerSyncTransport) async -> Outcome? {
        let offered: String
        do {
            // Computed from the BYTES here, whatever the transport says the
            // fingerprint is: the value that decides hangs on the key, so
            // a transport that handed on a label with somebody else's bytes
            // could not make a change look like no change.
            let service = try await transport.serviceKey(at: base)
            if let spoken = service.contract, spoken > contractVersion {
                Logger.library.notice("MAERSYNC sign-in stopped host=\(base.host ?? "-", privacy: .public) reason=the service speaks contract \(spoken, privacy: .public), this app \(contractVersion, privacy: .public)")
                return .serviceIsNewer(spoken)
            }
            guard let computed = ServiceKeyFingerprint.written(for: service.key) else { throw MaerSyncFailure.unreadable }
            offered = computed
        } catch let failure as MaerSyncFailure where failure == .serviceHasNoKey {
            return .serviceHasNoKey
        } catch let failure as MaerSyncFailure where failure == .serviceIsOlder {
            Logger.library.notice("MAERSYNC sign-in stopped host=\(base.host ?? "-", privacy: .public) reason=no key path; the service is older than this app")
            return .serviceIsOlder
        } catch let failure as MaerSyncFailure where failure == .status(403) {
            return .blockedHere
        } catch {
            let reason = MaerSyncFailure.reason(of: error)
            Logger.library.notice("MAERSYNC sign-in failed host=\(base.host ?? "-", privacy: .public) reason=\(reason, privacy: .public)")
            return Self.outcome(forTransportError: error)
        }
        let standing = ServiceKeyTrust.standing(held: ServiceKeyPin.held(for: base), offered: offered)
        if case .changed(let held, _) = standing, offered != acceptingKey {
            Logger.library.notice("MAERSYNC sign-in stopped host=\(base.host ?? "-", privacy: .public) reason=the service offers a different key than the one held")
            return .keyChanged(held: held, offered: offered)
        }
        // Held at the MEETING, before the secret travels: the token goes
        // through the tunnel, and the tunnel opens only against a held key
        // that is this one. A refused password afterwards does not unhold
        // it; this device did meet the service it talked to.
        if standing != .unchanged {
            ServiceKeyPin.hold(offered, for: base)
        }
        return nil
    }

    /// The contract version this app speaks.
    nonisolated static let contractVersion = 6

    /// Where on the way a failure happened, for its log line.
    enum Step: String, Sendable {
        case signInSalt = "sign-in salt"
        case signInToken = "sign-in token"
        case changeSalt = "password change salt"
        case change = "password change"
    }

    /// What a failure on the salt or the token way means for the person.
    /// EVERY failure says itself in the log, with its step: a refused
    /// password (401), a password the operator set (428) and too many tries
    /// (429) used to leave no line, and a failed change after the stretch was
    /// only visible at the service.
    nonisolated static func outcome(forSignInError error: Error, host: String?, step: Step) -> Outcome {
        Logger.library.notice("MAERSYNC \(step.rawValue, privacy: .public) failed host=\(host ?? "-", privacy: .public) reason=\(MaerSyncFailure.reason(of: error), privacy: .public)")
        switch error as? MaerSyncFailure {
        case .unauthorized?, .passwordChanged?:
            return .refused
        case .operatorSetPassword?:
            return .needsNewPassword
        case .tooManyAttempts(let seconds)?:
            return .tooManyAttempts(retryAfter: seconds)
        case .status(403)?:
            return .blockedHere
        case .serviceIsOlder?:
            return .serviceIsOlder
        default:
            return outcome(forTransportError: error)
        }
    }

    /// Whether the service answers at the address, without a token, and
    /// HOW it answered. A throw is the only real silence; a status is an
    /// answer and goes through the rule.
    static func test(address: String, transport: any MaerSyncTransport = MaerSyncHTTP()) async -> Reach {
        guard let base = MaerSyncPaths.normalized(address) else { return .badAddress }
        do {
            let status = try await transport.health(at: base)
            let reach = Self.reach(forStatus: status)
            if reach == .blockedHere {
                Logger.library.notice("MAERSYNC test blocked host=\(base.host ?? "-", privacy: .public) status=403; not reachable from this network")
            }
            return reach
        } catch {
            Logger.library.notice("MAERSYNC test silent host=\(base.host ?? "-", privacy: .public) reason=\(MaerSyncFailure.reason(of: error), privacy: .public)")
            return Self.isPlatformRefusal(error) ? .plainAddressRefused : .silent
        }
    }

    /// Stores what the service accepted, tells the session, and moves every
    /// runner built so far onto the service at once. Together with
    /// `signOut` the only place that writes the access (fence
    /// `AccessFollowersTests`).
    static func store(_ access: MaerSyncAccess, owner: String) {
        AppStorageKeys.maerSyncURLValue = access.baseURL.absoluteString
        AppStorageKeys.maerSyncOwnerValue = owner
        AppStorageKeys.setMaerSyncToken(access.token)
        MaerSyncCarriers.session.reloadAccess()
        // The feed credentials change their way with the access: from
        // here on they travel with the service, so the twins that sat in
        // Apple's iCloud keychain are written again as local items.
        PodcastFeedAuth.rewriteAll(by: "sign-in")
        AccessFollowers.followAll(by: "sign-in")
        // After the runners followed: on a change of account the address
        // belongs to the new account's register, not to the one that rests.
        rememberAddress(access)
        // Feeds that waited for a sign-in get one fresh attempt now.
        NotificationCenter.default.post(name: FeedAdoptionPending.accessArrived, object: nil,
                                        userInfo: ["by": "maer-sync sign-in"])
    }

    /// A sign-in that worked puts the ADDRESS into the register of known
    /// servers, so the next device is offered it under its field instead of
    /// having it typed by hand. Only the address: the
    /// token and the password never enter the register. It travels with the
    /// choices, which follow the sign-in and carry it over the service.
    nonisolated static func rememberAddress(_ access: MaerSyncAccess,
                                            defaults: UserDefaults = .standard) {
        KnownServers.remember(access.baseURL.absoluteString, service: .maerSync, defaults: defaults)
    }

    /// The fingerprint this device holds for the service at an address, for
    /// the settings page to show: a held key nobody can read cannot be
    /// compared with what the service prints about itself.
    static func heldKey(forAddress address: String) -> String? {
        guard let base = MaerSyncPaths.normalized(address) else { return nil }
        return ServiceKeyPin.held(for: base)
    }

    /// The person's answer to a changed key on a device that is already
    /// signed in: hold the offered key and let the rounds run again. The
    /// offered fingerprint comes from the event, so what is held is what
    /// was looked at.
    static func acceptKey(_ offered: String, forAddress address: String) {
        guard let base = MaerSyncPaths.normalized(address) else { return }
        ServiceKeyPin.hold(offered, for: base)
        // The same account under the service's new key: its state and the
        // runners' remembered account move along, nothing starts over.
        if let next = MaerSyncIdentity.stored() {
            MaerSyncCarriers.session.carryIdentity(to: next)
            AccessFollowers.carry(to: next)
        }
        MaerSyncCarriers.session.reloadAccess()
    }

    /// The token leaves the keychain; the address and the account stay
    /// in the form for the next sign-in. The held key stays too: a sign
    /// out is not a reason to forget whom this device has met. The feed key
    /// goes: the next sign-in derives it again from the password, and a
    /// device signed out holds nothing that opens a sealed block.
    static func signOut() {
        if let base = MaerSyncPaths.normalized(AppStorageKeys.maerSyncURLValue) { FeedKeyStore.forget(for: base) }
        AppStorageKeys.setMaerSyncToken("")
        MaerSyncCarriers.session.reloadAccess()
        // The way back: without the service the switch decides again, and
        // with the switch on the credentials return to the iCloud keychain.
        PodcastFeedAuth.rewriteAll(by: "sign-out")
        AccessFollowers.followAll(by: "sign-out")
    }
}
