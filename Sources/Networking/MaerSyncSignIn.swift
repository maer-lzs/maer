// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The sign-in to a Mär sync service. The address is checked for its
/// shape before anything is sent, the password is traded for a device
/// token once, and what the person typed is stored only when the service
/// said yes. The view shows the outcome; it decides nothing.
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
    }

    enum Reach: Equatable {
        case reached
        case badAddress
        case silent
    }

    static func perform(address: String, owner: String, secret: String,
                        device: String = SyncHistoryStore.deviceId,
                        transport: any MaerSyncTransport = MaerSyncHTTP()) async -> Outcome {
        let account = owner.trimmingCharacters(in: .whitespaces)
        guard !address.trimmingCharacters(in: .whitespaces).isEmpty, !account.isEmpty, !secret.isEmpty else {
            return .missing
        }
        guard let base = MaerSyncPaths.normalized(address) else { return .badAddress }
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

    /// Whether the service answers at the address, without a token.
    static func test(address: String, transport: any MaerSyncTransport = MaerSyncHTTP()) async -> Reach {
        guard let base = MaerSyncPaths.normalized(address) else { return .badAddress }
        do {
            return try await transport.health(at: base) ? .reached : .silent
        } catch {
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

    /// The token leaves the keychain; the address and the account stay
    /// in the form for the next sign-in.
    static func signOut() {
        AppStorageKeys.setMaerSyncToken("")
        MaerSyncCarriers.session.reloadAccess()
    }
}
