// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Whether a new address for a music server names another server than the
/// stored one. What one server handed out (a Jellyfin access token, a
/// Subsonic key) belongs to that server alone; sent with a request to
/// another, it gives that server's owner access to the first. So a switch
/// forgets it before the next client is built.
///
/// Another host, port or path is another server. The scheme is not: http
/// and https of the same host are one server, and so are letters in
/// another case, a trailing slash and the scheme's default port. An empty
/// stored address is no switch, there is nothing of a server to forget.
nonisolated enum ServerAddressSwitch {
    static func isSwitch(from stored: String, to new: String) -> Bool {
        let before = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        let after = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !before.isEmpty, !after.isEmpty else { return false }
        // An address that does not read is no proof of the same server.
        guard let old = place(of: before), let fresh = place(of: after) else { return true }
        return old != fresh
    }

    /// Whether new settings name another account: another server by
    /// `isSwitch`, or another user at the same server. What the stored
    /// account was handed out, and what it wrote, belong to it alone. Names
    /// are compared without case and surrounding spaces; an empty stored or
    /// new name is no switch (an empty field leaves the stored name), unless
    /// `unknownIsSwitch`: where the user is learned from the server, not
    /// typed, a stored account whose user or the new one's is unknown
    /// cannot be shown to be the same, and counts as another.
    static func isAccountSwitch(fromAddress: String, fromUser: String, toAddress: String, toUser: String,
                                unknownIsSwitch: Bool = false) -> Bool {
        if isSwitch(from: fromAddress, to: toAddress) { return true }
        let before = fromUser.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let after = toUser.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !fromAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !before.isEmpty, !after.isEmpty else { return unknownIsSwitch }
        return before != after
    }

    /// The password field of a form after a new address or user, and
    /// whether the stored password is forgotten. On a switch of the account
    /// the stored password goes with it: a field that still shows it is
    /// emptied, so the form does not write it back for the new one; a
    /// password typed for the new account stays. Without names given only
    /// the address decides.
    static func password(typed: String, stored: String,
                         from storedAddress: String, to new: String,
                         fromUser: String = "", toUser: String = "") -> (field: String, forgetsStored: Bool) {
        guard isAccountSwitch(fromAddress: storedAddress, fromUser: fromUser, toAddress: new, toUser: toUser)
        else { return (typed, false) }
        return (typed == stored ? "" : typed, true)
    }

    /// The one name of the server an address names by this rule: host,
    /// port and path; nil for an address that does not read. Two addresses
    /// with the same key are no switch.
    static func serverKey(of address: String) -> String? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let place = place(of: text) else { return nil }
        return place.host + (place.port.map { ":\($0)" } ?? "") + place.path
    }

    /// Host, port and path of an address, compared without case, without
    /// a trailing slash and without the default ports.
    private struct Place: Equatable {
        let host: String
        let port: Int?
        let path: String
    }

    private static func place(of address: String) -> Place? {
        let withScheme = address.contains("://") ? address : "https://" + address
        guard let parts = URLComponents(string: withScheme), let host = parts.host, !host.isEmpty else { return nil }
        var path = parts.path.lowercased()
        while path.hasSuffix("/") { path.removeLast() }
        let port = parts.port.flatMap { [80, 443].contains($0) ? nil : $0 }
        return Place(host: host.lowercased(), port: port, path: path)
    }
}
