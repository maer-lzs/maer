// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import os

/// Whether an access guard stands in front of a server (Cloudflare Access,
/// Authelia, Authentik and the like): the one place every server sheet asks
/// when its connection check failed, so a person learns to enter the
/// headers the guard wants instead of reading a decoding error.
nonisolated enum AccessGuard {
    /// The answer of a guard, not of the server: the request ended at
    /// another host (the guard's sign-in page), or 401/403 came back as a
    /// web page instead of the server's own answer.
    static func standsAhead(requested: URL, final: URL?, status: Int?, contentType: String?) -> Bool {
        if let asked = requested.host?.lowercased(), let reached = final?.host?.lowercased(), asked != reached {
            return true
        }
        guard let status, StatusMeaning.from(status: status) == .signIn else { return false }
        return contentType?.lowercased().contains("text/html") == true
    }

    /// The sentence a server sheet shows after its connection check failed:
    /// the guard's, when one stands in front of the server; the one of a
    /// refused local network (`LocalNetworkAccess`), when iOS keeps the app
    /// from the server at home; else the sheet's own.
    static func sentence(after failure: String, address typed: String) async -> String {
        guard let base = ServerHeaderRule.base(typed: typed) else { return failure }
        switch await ask(base) {
        case .guardAhead:
            return String(localized: "A sign-in stands in front of the server (Cloudflare Access, for example). Enter what it asks for under Custom Headers.")
        case .localNetworkRefused:
            return LocalNetworkAccess.sentence
        case .nothing:
            return failure
        }
    }

    /// What the one question at the server's address found.
    enum Answer: Equatable {
        case guardAhead
        case localNetworkRefused
        case nothing
    }

    /// Asks the server's address once, after a sheet's check failed: over
    /// the HTTP door, so it carries the headers entered for the server and
    /// no sign-in, and the door leaves those headers behind at another host.
    /// A guard that answered, a local server iOS keeps the app from, or
    /// nothing (the server itself answered, or it could not be reached).
    static func ask(_ base: URL) async -> Answer {
        var request = URLRequest(url: base)
        request.timeoutInterval = 10
        do {
            let (_, response) = try await HTTP.data(for: request, retry: false)
            let ahead = standsAhead(requested: base, final: response?.url, status: response?.statusCode,
                                    contentType: response?.value(forHTTPHeaderField: "Content-Type"))
            Logger.library.notice("ACCESSGUARD host=\(base.host ?? "-", privacy: .public) status=\(response?.statusCode ?? 0) ahead=\(ahead)")
            return ahead ? .guardAhead : .nothing
        } catch {
            // The door logs the failure; an address that cannot be reached
            // names no guard. A local one that says offline while the device
            // is online is the refused local network.
            let online = await MainActor.run { NetworkMonitor.shared.isConnected }
            if let code = (error as? URLError)?.code,
               LocalNetworkAccess.isDenied(host: base.host, code: code, deviceOnline: online) {
                Logger.library.notice("ACCESSGUARD host=\(base.host ?? "-", privacy: .public) local network refused")
                return .localNetworkRefused
            }
            return .nothing
        }
    }

    /// Whether a guard stands in front of the server (`ask`).
    static func standsAhead(of base: URL) async -> Bool {
        await ask(base) == .guardAhead
    }
}
