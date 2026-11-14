// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The date of an episode in the future (a feed that publishes ahead)
/// shows the appointment, „heute 09:05“ or „morgen 09:05“, instead of „in 8 Stunden“;
/// the past stays relative. One rule for every surface with an episode date.
struct EpisodeDateLineTests {
    /// A broadcast date is a day, not a point in time: in Los Angeles, Zurich
    /// and Tokyo the same day; what is no day yields no line.
    @Test("a broadcast date shows the same day in every time zone")
    func anAirDateIsTheSameDayInEveryZone() {
        let german = Locale(identifier: "de_DE")
        for zone in ["America/Los_Angeles", "Europe/Zurich", "Asia/Tokyo", "Pacific/Honolulu"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            #expect(EpisodeDateLine.airDay("1948-12-07", calendar: calendar, locale: german) == "7.12.1948", "\(zone)")
        }
        for broken in ["1948-02-31", "1948-12", "07.12.1948", "", "1948-1-7"] {
            #expect(EpisodeDateLine.airDay(broken, calendar: zurich, locale: german) == nil, "\(broken)")
        }
    }

    private var zurich: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        zurich.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    @Test("The table: before, today, past midnight, the day after tomorrow, in ten days")
    func theKinds() {
        let evening = date(28, 20, 0)
        let night = date(28, 0, 35)
        #expect(EpisodeDateLine.kind(of: date(28, 19, 0), now: evening, calendar: zurich) == .past)
        #expect(EpisodeDateLine.kind(of: date(28, 21, 0), now: evening, calendar: zurich) == .today, "plus one hour")
        #expect(EpisodeDateLine.kind(of: date(28, 9, 5), now: night, calendar: zurich) == .today,
                "the device case: 00:35, the episode at 09:05 the same day")
        #expect(EpisodeDateLine.kind(of: date(29, 4, 0), now: evening, calendar: zurich) == .tomorrow,
                "plus eight hours across midnight")
        #expect(EpisodeDateLine.kind(of: date(30, 2, 0), now: evening, calendar: zurich) == .later, "plus thirty hours")
        #expect(EpisodeDateLine.kind(of: date(28, 20, 0).addingTimeInterval(10 * 86_400), now: evening,
                                     calendar: zurich) == .later, "plus ten days")
    }

    @Test("Today and tomorrow name the time of day, further away date and time of day, the past stays relative")
    func theTexts() {
        let night = date(28, 0, 35)
        let locale = Locale(identifier: "de_CH")
        let today = EpisodeDateLine.text(of: date(28, 9, 5), now: night, calendar: zurich, locale: locale)
        let tomorrow = EpisodeDateLine.text(of: date(29, 9, 5), now: night, calendar: zurich, locale: locale)
        let later = EpisodeDateLine.text(of: date(30, 9, 5), now: night, calendar: zurich, locale: locale)
        // The time follows the locale: de_CH writes 9:05, de_DE 09:05.
        #expect(today.contains("9:05") && tomorrow.contains("9:05") && later.contains("9:05"), "\(today) | \(tomorrow) | \(later)")
        #expect(today != tomorrow, "today and tomorrow say which day")
        #expect(later.contains("30"), "further out the date is named: \(later)")
        #expect(!today.contains("in "), "no \"in 8 hours\": \(today)")
        #expect(EpisodeDateLine.text(ms: nil).isEmpty && EpisodeDateLine.text(ms: 0).isEmpty)
    }

    @Test("Every surface with an episode date asks the one rule", .needsTheSources)
    func everySurfaceAsksTheOneRule() throws {
        func source(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let helpers = try source("Sources/Views/Podcasts/PodcastHelpers.swift")
        let dateText = try #require(functionBody(of: "func relativeDateText(_ item: LibraryItem) -> String {", in: helpers))
        #expect(dateText.contains("EpisodeDateLine.text(ms: item.addedAt)"))
        let components = try source("Sources/Views/Podcasts/PodcastComponents.swift")
        #expect(components.contains("Text(EpisodeDateLine.text(ms: info.lastUpdated))"), "the show tile, Last updated")
        // The episode row, the continue row's fallback (in the cards' status
        // words) and the episode page go through relativeDateText.
        #expect(components.components(separatedBy: "relativeDateText(item)").count - 1 == 1)
        let statusWords = try source("Sources/Views/CardStatusLine.swift")
        #expect(statusWords.contains("relativeDateText(item)"), "the continue card's fallback date")
        let detail = try source("Sources/Views/Podcasts/PodcastEpisodeDetailView.swift")
        #expect(detail.contains("relativeDateText(item)"))
        // No episode date is formatted past the rule any more.
        #expect(!components.contains("info.lastUpdated / 1000"))
    }
}
#endif
