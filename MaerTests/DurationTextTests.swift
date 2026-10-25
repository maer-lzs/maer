// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// One way to write a duration: "x hr y min" and "y min", in German
/// "x Std. y Min." and "y Min.". Two forms stood side by side before
/// (episodes and the catalogue wrote "x h y min", German "x Std y min").
struct DurationTextTests {
    @Test("die Dauer wird in Stunden und Minuten geteilt, nie negativ")
    func partsSplitTheMinutes() {
        let cases: [(minutes: Int, hours: Int, rest: Int)] = [(0, 0, 0), (59, 0, 59), (60, 1, 0), (95, 1, 35), (-5, 0, 0)]
        for c in cases {
            let split = DurationText.parts(minutes: c.minutes)
            #expect(split.hours == c.hours && split.minutes == c.rest, "\(c.minutes) min")
        }
    }

    /// The written output on a full hour: "1 Std.", never "1 Std. 0 Min."
    /// (the sleep menu's 60, a wait, a book of exactly two hours).
    @Test("eine volle Stunde steht als Stunden allein, nie mit null Minuten")
    func aFullHourStandsAlone() {
        for minutes in [60, 120, 180] {
            let length = DurationText.length(minutes: minutes)
            #expect(length == DurationText.hours(minutes / 60), "\(minutes) min as \(length)")
            #expect(!length.contains(" 0 "), "\(length)")
            let left = DurationText.remaining(minutes: minutes)
            #expect(!left.contains(" 0 "), "\(left)")
        }
        #expect(DurationText.length(minutes: 61).contains(" 1 "), "one minute past the hour stays written")
        #expect(DurationText.length(seconds: 7_200) == DurationText.hours(2))
        // The unit itself, in any language: two hours never read like two
        // minutes, so the hour form carries an hour unit, not a minute one.
        #expect(DurationText.length(minutes: 120) != DurationText.length(minutes: 2))
        #expect(DurationText.remaining(minutes: 120) != DurationText.remaining(minutes: 2))
        #expect(DurationText.hours(2) != DurationText.length(minutes: 2))
    }

    /// The German side of the rule: the catalogue carries exactly the one
    /// form, and no other value writes a duration in a second form.
    @Test("der Katalog traegt die Dauer in genau einer Form, deutsch mit Punkt", .needsTheSources)
    func theCatalogCarriesOneForm() throws {
        let data = try Data(contentsOf: SourceTree.root.appendingPathComponent("Sources/Localizable.xcstrings"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: [String: Any]])
        func german(_ key: String) -> String? {
            ((strings[key]?["localizations"] as? [String: Any])?["de"] as? [String: Any])
                .flatMap { $0["stringUnit"] as? [String: Any] }?["value"] as? String
        }
        #expect(german("%lld hr %lld min") == "%lld Std. %lld Min.")
        #expect(german("%lld min") == "%lld Min.")
        #expect(german("%lld hr") == "%lld Std.")
        #expect(german("%lld hr %lld min left") == "noch %lld Std. %lld Min.")
        #expect(german("%lld min left") == "noch %lld Min.")
        #expect(german("%lld hr left") == "noch %lld Std.")
        #expect(strings["%lld h %lld min"] == nil, "the second form is back in the catalogue")
        let second = try NSRegularExpression(pattern: #"%lld min\b|\bStd(?!\.)\b"#)
        var offenders: [String] = []
        for key in strings.keys {
            guard let value = german(key) else { continue }
            if second.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil {
                offenders.append("\(key) -> \(value)")
            }
        }
        #expect(offenders.isEmpty, "a German duration in a second form: \(offenders.sorted())")
    }

    /// Finds a duration written by hand: an interpolation followed by an
    /// hour or minute unit inside a string literal.
    static func handWritten(in code: String) -> Int {
        // One interpolation at a time: its content may hold one pair of
        // parentheses, never a quote, so two units in one literal count twice.
        let pattern = try! NSRegularExpression(pattern: #"\\\((?:[^()"\n]|\([^()"\n]*\))*\) (h|hr|min)(?![A-Za-z])"#)
        return pattern.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
    }

    /// The code side: only the rule writes an hour or minute unit. The
    /// drive mode's clock form ("1:05 h") is a format, not an interpolation
    /// with a unit, and its minutes go through the rule; the logo report's
    /// age line is German diagnosis text and an age, not a duration.
    @Test("nur die Regel schreibt eine Dauer; die benannte Ausnahme mit Grund", .needsTheSources)
    func onlyTheRuleWritesADuration() throws {
        #expect(Self.handWritten(in: #"return "\(m) min""#) == 1, "the finder sees a minute form")
        #expect(Self.handWritten(in: #"String(localized: "\(total / 60) h \(total % 60) min")"#) == 2)
        #expect(Self.handWritten(in: #"Text("\(left) in chapter · ends \(time)")"#) == 0)
        let allowed: [String: (count: Int, reason: String)] = [
            "DurationText.swift": (8, "the rule itself"),
            "RadioLogoReport.swift": (1, "an age in German diagnosis text, not a duration")
        ]
        var found: [String: Int] = [:]
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            let count = Self.handWritten(in: code)
            if count > 0 { found[file.lastPathComponent] = count }
        }
        let drift = StockDrift.findings(counts: found, stock: allowed.mapValues(\.count))
        #expect(drift.isEmpty, "a duration written outside the rule, or a stale exception: \(drift)")
    }

    @Test("die Zeile unter dem Titel nennt, was endet: Buch, Folge, Sammlung, Album; ein Lied nur seine Restzeit")
    func theRemainingLineNamesWhatEnds() {
        #expect(RemainingLine.form(isMusic: false, isPodcast: false, hasParts: false, chapterCount: 12) == .book)
        #expect(RemainingLine.form(isMusic: false, isPodcast: true, hasParts: false, chapterCount: 4) == .episode)
        #expect(RemainingLine.form(isMusic: false, isPodcast: false, hasParts: true, chapterCount: 30) == .collection)
        #expect(RemainingLine.form(isMusic: true, isPodcast: false, hasParts: false, chapterCount: 9) == .album)
        #expect(RemainingLine.form(isMusic: true, isPodcast: false, hasParts: false, chapterCount: 1) == .song)
    }

    @Test("der Katalog traegt jede Form der Zeile deutsch und englisch, die alte ohne Gegenstand nicht mehr", .needsTheSources)
    func theCatalogCarriesEveryForm() throws {
        let catalog = try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Localizable.xcstrings"),
                                 encoding: .utf8)
        for (key, german) in [("%@ in chapter · book ends %@", "%@ im Kapitel · Buch endet %@"),
                              ("%@ in chapter · episode ends %@", "%@ im Kapitel · Folge endet %@"),
                              ("%@ in part · collection ends %@", "%@ im Teil · Sammlung endet %@"),
                              ("%@ · album ends %@", "%@ · Album endet %@")] {
            #expect(catalog.contains("\"\(key)\" : {"), "missing \(key)")
            #expect(catalog.contains("\"value\" : \"\(german)\""), "missing \(german)")
        }
        #expect(!catalog.contains("\"%@ in chapter · ends %@\""), "the line still says ends without what")
        #expect(!catalog.contains("\"%@ · ends %@\""), "the line still says ends without what")
    }
}
#endif
