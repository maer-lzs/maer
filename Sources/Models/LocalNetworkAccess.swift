// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// iOS refused Mär the local network (the question "find devices on local
/// networks" answered with "Don't Allow"): a server at home then answers
/// "offline" while the device is online. The app tells that apart and says
/// it in its own sentence, with the way to the settings.
nonisolated enum LocalNetworkAccess {
    /// Whether an address is on the local network as iOS's privacy rule
    /// counts it: the private IPv4 ranges, link-local, a `.local` name, and
    /// the local IPv6 ranges. Loopback is not asked about and is none.
    static func isLocal(host: String?) -> Bool {
        guard let host = host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")), !host.isEmpty else {
            return false
        }
        if host.hasSuffix(".local") { return true }
        if host.contains(":") { return host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// Whether a failed request means iOS refused the local network: the
    /// server is local, the request says the device is offline, and the
    /// device is online. A server that is off times out or refuses, and
    /// that is not this.
    static func isDenied(host: String?, code: URLError.Code, deviceOnline: Bool) -> Bool {
        isLocal(host: host) && deviceOnline && code == .notConnectedToInternet
    }

    /// The sentence a server form shows then.
    static var sentence: String {
        String(localized: "Mär may not reach devices on your local network. Allow it in Settings under Mär, Local Network.")
    }
}
