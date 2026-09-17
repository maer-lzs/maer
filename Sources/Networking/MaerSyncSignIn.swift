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
    }

    enum Reach: Equatable {
        case reached
        case badAddress
        /// The same case the sign-in already tells apart: the service
        /// answered with a refusal from outside its network, which is a
        /// different end of the line than a service that says nothing.
        case blockedHere
        case silent
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
    static func perform(address: String, owner: String, secret: String,
                        acceptingKey: String? = nil,
                        device: String = SyncHistoryStore.deviceId,
                        transport: any MaerSyncTransport = MaerSyncHTTP()) async -> Outcome {
        let account = owner.trimmingCharacters(in: .whitespaces)
        guard !address.trimmingCharacters(in: .whitespaces).isEmpty, !account.isEmpty, !secret.isEmpty else {
            return .missing
        }
        guard let base = MaerSyncPaths.normalized(address) else { return .badAddress }
        let offered: String
        do {
            // Computed from the BYTES here, whatever the transport says the
            // fingerprint is: the value that decides hangs on the key, so
            // a transport that handed on a label with somebody else's bytes
            // could not make a change look like no change.
            let key = try await transport.serviceKey(at: base).key
            guard let computed = ServiceKeyFingerprint.written(for: key) else { throw MaerSyncFailure.unreadable }
            offered = computed
        } catch let failure as MaerSyncFailure where failure == .serviceHasNoKey {
            return .serviceHasNoKey
        } catch let failure as MaerSyncFailure where failure == .status(404) {
            Logger.library.notice("MAERSYNC sign-in stopped host=\(base.host ?? "-", privacy: .public) reason=no key path; the service is older than this app")
            return .serviceIsOlder
        } catch let failure as MaerSyncFailure where failure == .status(403) {
            return .blockedHere
        } catch {
            let reason = MaerSyncFailure.reason(of: error)
            Logger.library.notice("MAERSYNC sign-in failed host=\(base.host ?? "-", privacy: .public) reason=\(reason, privacy: .public)")
            return .unreachable(reason)
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
        do {
            let token = try await transport.token(owner: account, secret: secret, device: device, at: base)
            Logger.library.notice("MAERSYNC signed in host=\(base.host ?? "-", privacy: .public)")
            return .signedIn(MaerSyncAccess(baseURL: base, token: token), account: account)
        } catch let failure as MaerSyncFailure where failure == .unauthorized {
            return .refused
        } catch let failure as MaerSyncFailure where failure == .status(403) {
            Logger.library.notice("MAERSYNC sign-in blocked host=\(base.host ?? "-", privacy: .public) reason=status(403); not reachable from this network")
            return .blockedHere
        } catch {
            let reason = MaerSyncFailure.reason(of: error)
            Logger.library.notice("MAERSYNC sign-in failed host=\(base.host ?? "-", privacy: .public) reason=\(reason, privacy: .public)")
            return .unreachable(reason)
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
            return .silent
        }
    }

    /// Stores what the service accepted and tells the session. The
    /// carriers themselves are chosen at start-up, so the pot and the
    /// claim move to the service with the next start.
    static func store(_ access: MaerSyncAccess, owner: String) {
        AppStorageKeys.maerSyncURLValue = access.baseURL.absoluteString
        AppStorageKeys.maerSyncOwnerValue = owner
        AppStorageKeys.setMaerSyncToken(access.token)
        MaerSyncCarriers.session.reloadAccess()
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
        MaerSyncCarriers.session.reloadAccess()
    }

    /// The token leaves the keychain; the address and the account stay
    /// in the form for the next sign-in. The held key stays too: a sign
    /// out is not a reason to forget whom this device has met.
    static func signOut() {
        AppStorageKeys.setMaerSyncToken("")
        MaerSyncCarriers.session.reloadAccess()
    }
}
