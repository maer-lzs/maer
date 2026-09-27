// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// An ISO-8601 timestamp as a music server sends it (Subsonic `created`,
/// playlist `changed`): with fractional seconds of any length or without,
/// `Z` or an offset. A missing zone, a date alone or a space for the `T` is
/// no timestamp.
///
/// Whole milliseconds, cut and not rounded: that is what the pair of
/// `ISO8601DateFormatter`s this replaces gave, measured on the same forms
/// (`ServerTimestampTests`). The format style keeps digits past the
/// millisecond, which Navidrome (nine) and .NET servers (seven) send, so the
/// cut is what keeps every sort where it was. One style reads both forms:
/// parsing with the plain style takes fractional seconds too (measured on
/// the whole table; a first pass with `includingFractionalSeconds` decided
/// nothing). `Date.ISO8601FormatStyle` is a `Sendable` value, so no shared
/// formatter needs an escape.
nonisolated enum ServerTimestamp {
    static func milliseconds(_ raw: String) -> Double? {
        // bearable, because text that is no timestamp answers nil, which is the answer asked for
        guard let date = try? Date(raw, strategy: Date.ISO8601FormatStyle()) else { return nil }
        return (date.timeIntervalSince1970 * 1000).rounded(.down)
    }

    static func date(_ raw: String) -> Date? {
        milliseconds(raw).map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}
