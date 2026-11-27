// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

actor HostReads {
    static let archive = HostReads(limit: 4)
    let limit: Int
    init(limit: Int) { self.limit = limit }
    func run<T: Sendable>(_ op: @Sendable () async throws -> T) async rethrows -> T { try await op() }
}
