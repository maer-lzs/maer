// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Where a source's sign-in may travel, pure: a sign-in, a token or a key
/// of a source goes only to that source's own host. An address a feed or a
/// server names on another host (a CDN, a counting service in front of the
/// file) is asked without it.
nonisolated enum SignInReach {
    /// Whether the sign-in of the source at `own` may travel to `target`:
    /// the same host, compared without case, and never from https down to
    /// http. A source whose own address is not known binds its sign-in to
    /// no host.
    static func mayCarry(own: URL?, target: URL) -> Bool {
        guard let host = own?.host?.lowercased(), !host.isEmpty, target.host?.lowercased() == host else { return false }
        if own?.scheme?.lowercased() == "https", target.scheme?.lowercased() != "https" { return false }
        return true
    }
}
