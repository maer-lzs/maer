// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The one way the app writes a duration: "x hr y min" or "y min", in
/// German "x Std. y Min." or "y Min.", and a remaining time the same with
/// "left". Two forms stood side by side ("x h y min" on episodes and the
/// catalogue), so one person saw both. Positions in a clock form
/// (h:mm:ss) are a different question and stay where they are.
nonisolated enum DurationText {
    /// Whole minutes split for the text.
    static func parts(minutes total: Int) -> (hours: Int, minutes: Int) {
        let total = max(0, total)
        return (total / 60, total % 60)
    }

    /// Whole hours alone, where a row counts hours (the radio card).
    static func hours(_ count: Int) -> String {
        String(localized: "\(max(0, count)) hr")
    }

    /// A length: whole minutes, rounded down.
    static func length(seconds: Double) -> String {
        length(minutes: Int(max(0, seconds) / 60))
    }

    static func length(minutes total: Int) -> String {
        let (hours, minutes) = parts(minutes: total)
        if hours > 0 { return String(localized: "\(hours) hr \(minutes) min") }
        return String(localized: "\(minutes) min")
    }

    /// What is left: minutes rounded UP, so "0 min" stands only at the end.
    static func remaining(seconds: Double) -> String {
        remaining(minutes: ProgressMark.minutesLeft(seconds))
    }

    static func remaining(minutes total: Int) -> String {
        let (hours, minutes) = parts(minutes: total)
        if hours > 0 { return String(localized: "\(hours) hr \(minutes) min left") }
        return String(localized: "\(minutes) min left")
    }
}
