// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The date line of an episode, the one rule every surface with an episode
/// date asks. A past date reads relative, as before ("2 days ago"). A date in
/// the future is a feed that publishes ahead of time, and "in 8 hours" read
/// as a mistake on the device; it shows the appointment instead: "today
/// 09:05", "tomorrow 09:05", further out the date with the time. The episode
/// stays listed and playable either way.
nonisolated enum EpisodeDateLine {
    enum Kind: Equatable, Sendable {
        case past, today, tomorrow, later
    }

    static func kind(of date: Date, now: Date, calendar: Calendar) -> Kind {
        guard date > now else { return .past }
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) { return .tomorrow }
        return .later
    }

    static func text(of date: Date, now: Date = Date(), calendar: Calendar = .current,
                     locale: Locale = .current) -> String {
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                                   calendar: calendar, timeZone: calendar.timeZone))
        switch kind(of: date, now: now, calendar: calendar) {
        case .past:
            return date.formatted(Date.RelativeFormatStyle(presentation: .named, locale: locale, calendar: calendar))
        case .today:
            return String(localized: "today \(time)")
        case .tomorrow:
            return String(localized: "tomorrow \(time)")
        case .later:
            return date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale,
                                                   calendar: calendar, timeZone: calendar.timeZone))
        }
    }

    /// The episode's date from its epoch milliseconds, or nothing without one.
    static func text(ms: Double?) -> String {
        guard let ms, ms > 0 else { return "" }
        return text(of: Date(timeIntervalSince1970: ms / 1000))
    }
}
