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
    /// the guard's, when one stands in front of the server, else the
    /// sheet's own.
    static func sentence(after failure: String, address typed: String) async -> String {
        guard let base = ServerHeaderRule.base(typed: typed), await standsAhead(of: base) else { return failure }
        return String(localized: "A sign-in stands in front of the server (Cloudflare Access, for example). Enter what it asks for under Custom Headers.")
    }

    /// Asks the server's address once, after a sheet's check failed: over
    /// the HTTP door, so it carries the headers entered for the server and
    /// no sign-in, and the door leaves those headers behind at another host.
    /// True when a guard answered; false when the server itself answered or
    /// the address could not be reached at all.
    static func standsAhead(of base: URL) async -> Bool {
        var request = URLRequest(url: base)
        request.timeoutInterval = 10
        do {
            let (_, response) = try await HTTP.data(for: request, retry: false)
            let ahead = standsAhead(requested: base, final: response?.url, status: response?.statusCode,
                                    contentType: response?.value(forHTTPHeaderField: "Content-Type"))
            Logger.library.notice("ACCESSGUARD host=\(base.host ?? "-", privacy: .public) status=\(response?.statusCode ?? 0) ahead=\(ahead)")
            return ahead
        } catch {
            // The door logs the failure; an address that cannot be reached
            // names no guard, and the sheet keeps its own sentence.
            return false
        }
    }
}
