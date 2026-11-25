// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

nonisolated enum IdentityCarry {
    struct Side: Equatable, Sendable {
        var stands: [String: [Double]] = [:]
        var standsVersion: String? = nil
        var queue: [String: [Double]] = [:]
        var removals: Set<String> = []
        var playlistsPending: Data? = nil
        var choicesPending: Data? = nil
    }

    static func merged(source: Side, target: Side) -> (side: Side, dropped: [String]) { (source, []) }
}
