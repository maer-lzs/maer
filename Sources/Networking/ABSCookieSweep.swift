// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The cookies an Audiobookshelf server set in the store of the app's
/// requests before its sign-in kept them out: `refresh_token` (a renewal
/// token for 30 days, set by a password sign-in that did not ask for its
/// tokens in the answer) and `auth_method`. Only these two names, and only
/// at the server's own host: any other cookie there may belong to a guard
/// in front of the server and stays.
nonisolated enum ABSCookieSweep {
    static let names: Set<String> = ["refresh_token", "auth_method"]

    /// The cookies of the store that go: the two names, set by the server's
    /// host itself (a cookie without a domain of its own carries the host).
    static func doomed(_ cookies: [HTTPCookie], server: URL) -> [HTTPCookie] {
        guard let host = server.host?.lowercased() else { return [] }
        return cookies.filter { cookie in
            names.contains(cookie.name) && cookie.domain.lowercased() == host
        }
    }

    /// Removes those cookies from the store of the app's requests and writes
    /// how many it removed to the log.
    @discardableResult
    static func sweep(server: URL, store: HTTPCookieStorage? = HTTP.cookieStore(.api)) -> Int {
        guard let store else { return 0 }
        let gone = doomed(store.cookies ?? [], server: server)
        for cookie in gone { store.deleteCookie(cookie) }
        Logger.library.notice("AUTH server cookies swept host=\(server.host ?? "-", privacy: .public) count=\(gone.count, privacy: .public)")
        return gone.count
    }
}
