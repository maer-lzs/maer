// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Audiobooks downloaded while you listen: what to download, what goes.
nonisolated enum AudiobookPreload {
    /// A book as the rule sees it.
    struct Book: Equatable, Sendable {
        let id: String
        let bytes: Int64
        let lastHeardMs: Double
        var finishedAtMs: Double? = nil
    }

    struct Plan: Equatable, Sendable {
        var download: [String] = []
        var remove: [String] = []
    }

    static let budgetsGB: [Int] = []
    static let defaultBudgetGB = 0
    static let reserveBytes: Int64 = 0
    static let keepAfterFinishMs: Double = 0

    static func budgetBytes(gb: Int) -> Int64 { 0 }
    static func mayLoad(enabled: Bool, onWiFi: Bool) -> Bool { false }
    static func candidates(started: String?, continueRow: [String], nextInSeries: String?) -> [String] { [] }
    static func plan(wanted: [Book], held: [Book], budgetBytes: Int64, freeBytes: Int64, nowMs: Double) -> Plan { Plan() }
}
