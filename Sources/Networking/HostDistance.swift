// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The ONE memory of which host refused us and when, shared by every
/// path that speaks to it: the first stock fetch, the shelf previews,
/// the browse page, the decade shelves, the music shelves. Measured on
/// the device: three archive.org surfaces fell on `-1004` within a
/// minute while Gutenberg loaded fine, and the distance the stock fetch
/// kept did not reach the shelf queries, which kept knocking.
///
/// The rule (`CatalogHostGuard.isBlocked`) is pure and tested; this is
/// only the ledger.
@MainActor
enum HostDistance {
    private(set) static var failedAt: [String: Date] = [:]

    static func isBlocked(_ host: String, now: Date = Date()) -> Bool {
        CatalogHostGuard.isBlocked(host, since: failedAt, now: now)
    }

    static func note(_ host: String, at date: Date = Date()) {
        failedAt[host] = date
    }

    #if DEBUG
    static func _reset() { failedAt = [:] }
    #endif
}
