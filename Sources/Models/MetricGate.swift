// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Whether this run receives MetricKit's payloads: in a build from Xcode
/// and in TestFlight, never in the App Store. The same build goes from
/// TestFlight to the Store, so the question is asked at run time, never at
/// compile time.
nonisolated enum MetricGate {
    /// The App Store environment that signed this install, as far as it was
    /// read; `unknown` when the read failed or nobody is signed in.
    enum Environment: String, Sendable, CaseIterable {
        case xcode, sandbox, production, unknown
    }

    /// What the gate has said in this run. It is `undecided` until the
    /// environment is read at start; a play from Siri or a shortcut on a
    /// cold start can come first, and nothing waits for the answer. The raw
    /// value is what a log line names.
    enum Decision: String, Sendable, CaseIterable {
        case undecided, open, closed
    }

    /// A Debug build is on. A Release build is on where the environment is
    /// Xcode's or the sandbox, which is where TestFlight installs come
    /// from. An environment that could not be read is off: the gate fails
    /// closed, so an install from the App Store never measures.
    static func receives(environment: Environment, isDebugBuild: Bool) -> Bool {
        if isDebugBuild { return true }
        switch environment {
        case .xcode, .sandbox: return true
        case .production, .unknown: return false
        }
    }

    /// Whether the environment may be asked of the App Store. An install
    /// that carries a provisioning profile (a build from Xcode, or an ad hoc
    /// one) holds no App Store transaction; asking for one fetched it, and
    /// the system asked the person to sign in at every start (measured on a
    /// device without an Apple account, iOS 18.0.1). Such an install is
    /// Xcode's, without asking.
    static func asksTheStore(carriesProfile: Bool) -> Bool {
        !carriesProfile
    }
}

/// One MetricKit payload as this device keeps it: the few numbers the
/// measuring plan reads, never a title, an id or an address. Kept for two
/// weeks on the device and never sent anywhere.
nonisolated struct MetricRecord: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// The daily numbers: time, CPU, memory, the app's signposts.
        case metrics
        /// What went wrong in the period: hangs and crashes.
        case diagnostics
    }

    var kind: Kind
    var begin: Date
    var end: Date
    var cpuSeconds: Double?
    var foregroundSeconds: Double?
    var backgroundSeconds: Double?
    var peakMemoryMB: Double?
    /// The time the app played in the background, so the CPU time can be
    /// set against an hour of playing.
    var backgroundAudioSeconds: Double?
    /// Bytes moved over the network in the period, in megabytes.
    var wifiUpMB: Double?
    var wifiDownMB: Double?
    var cellularUpMB: Double?
    var cellularDownMB: Double?
    /// What the app wrote to the disk in the period, in megabytes.
    var logicalWritesMB: Double?
    /// The time the app hung in the period and how many hangs that was.
    var hangTime: HangTime?
    /// How long a launch took to its first frame, and a return from the
    /// background to the app: how many, and their mean.
    var firstDraw: Durations?
    var resume: Durations?
    /// The share of the time the app hitched while scrolling, and (iOS 26
    /// and later) during any tracked animation, in the unit MetricKit
    /// hands over.
    var scrollHitch: Ratio?
    var hitch: Ratio?
    /// How often the app was ended in the foreground and in the
    /// background, by reason; only reasons with a count. Nil where the
    /// payload carried no exits, empty where it counted none.
    var foregroundExits: [String: Int]?
    var backgroundExits: [String: Int]?
    /// Hangs and crashes are what a diagnostics record counts; a metrics
    /// record does not measure them and its line does not name them.
    var hangs: Int = 0
    var crashes: Int = 0
    /// What each signpost name cost in the period.
    var signposts: [String: SignpostCost] = [:]

    /// One signpost name in one period: how often its interval ran, the CPU
    /// time all of them took together, and how long one took on average.
    struct SignpostCost: Codable, Equatable, Sendable {
        var count: Int
        var cpuSeconds: Double?
        var meanSeconds: Double?
    }

    /// One signpost as MetricKit hands it over: its name, its count, its
    /// CPU time and its duration histogram (bucket edges in seconds).
    struct SignpostReading: Sendable {
        var name: String
        var count: Int
        var cpuSeconds: Double?
        var buckets: [(start: Double, end: Double, count: Int)]
    }

    /// The hang time of one period: how many hangs, and their duration
    /// added up.
    struct HangTime: Codable, Equatable, Sendable {
        var count: Int
        var seconds: Double
    }

    /// Durations of one kind in one period: how many, and how long one took
    /// on average; no mean where none was counted.
    struct Durations: Codable, Equatable, Sendable {
        var count: Int
        var meanSeconds: Double?
    }

    /// A ratio as MetricKit hands it over: the value and its unit's symbol,
    /// spaces taken out so the line keeps one word per size. The header
    /// calls the hitch ratios dimensionless; which unit a device reports is
    /// not measured, so the record keeps the one it got.
    struct Ratio: Codable, Equatable, Sendable {
        var value: Double
        var unit: String
    }

    /// The durations of a histogram: the count, and the mean with each
    /// bucket at its middle.
    static func durations(_ buckets: [(start: Double, end: Double, count: Int)]) -> Durations {
        Durations(count: buckets.reduce(0) { $0 + $1.count }, meanSeconds: meanSeconds(buckets))
    }

    /// A ratio with its unit's symbol, spaces taken out.
    static func ratio(_ value: Double, symbol: String) -> Ratio {
        Ratio(value: value, unit: symbol.filter { !$0.isWhitespace })
    }

    /// The hang time of a histogram, each bucket counted at its middle. A
    /// histogram without a count is a measured zero, not an unknown.
    static func hangTime(_ buckets: [(start: Double, end: Double, count: Int)]) -> HangTime {
        HangTime(count: buckets.reduce(0) { $0 + $1.count },
                 seconds: buckets.reduce(0.0) { $0 + ($1.start + $1.end) / 2 * Double($1.count) })
    }

    /// The exits of one side by reason, the reasons that counted none left
    /// out.
    static func exits(_ counts: KeyValuePairs<String, Int>) -> [String: Int] {
        Dictionary(counts.filter { $0.value > 0 }.map { ($0.key, $0.value) }, uniquingKeysWith: +)
    }

    /// Whether the record says anything: a period, or at least one number.
    /// A record with neither is no measurement and is not shown.
    var isMeasurement: Bool {
        let numbers: [Double?] = [cpuSeconds, foregroundSeconds, backgroundSeconds, peakMemoryMB, backgroundAudioSeconds,
                                  wifiUpMB, wifiDownMB, cellularUpMB, cellularDownMB, logicalWritesMB]
        return end > begin || numbers.contains { $0 != nil } || hangTime != nil || firstDraw != nil || resume != nil
            || scrollHitch != nil || hitch != nil || foregroundExits != nil
            || backgroundExits != nil || hangs > 0 || crashes > 0 || !signposts.isEmpty
    }

    /// The records the measurement page and its text show.
    static func shown(_ records: [MetricRecord]) -> [MetricRecord] {
        records.filter(\.isMeasurement)
    }

    /// The mean duration of a histogram, each bucket counted at its middle;
    /// nil when no bucket counted anything.
    static func meanSeconds(_ buckets: [(start: Double, end: Double, count: Int)]) -> Double? {
        let counted = buckets.reduce(0) { $0 + $1.count }
        guard counted > 0 else { return nil }
        return buckets.reduce(0.0) { $0 + ($1.start + $1.end) / 2 * Double($1.count) } / Double(counted)
    }

    /// The readings by name. A name that comes in several categories
    /// stands once: the counts and the CPU times add up, and the mean is
    /// taken over all the buckets together.
    static func costs(_ readings: [SignpostReading]) -> [String: SignpostCost] {
        Dictionary(grouping: readings, by: \.name).mapValues { group in
            let cpu = group.compactMap(\.cpuSeconds)
            return SignpostCost(count: group.reduce(0) { $0 + $1.count },
                                cpuSeconds: cpu.isEmpty ? nil : cpu.reduce(0, +),
                                meanSeconds: meanSeconds(group.flatMap(\.buckets)))
        }
    }

    /// How long a record stays on the device.
    static let keepDays = 14

    /// The records kept after new ones arrive: everything whose period
    /// ended within the keep span, oldest first. A record that arrives twice
    /// (the same kind and period) stands once.
    static func kept(_ held: [MetricRecord], adding new: [MetricRecord], now: Date) -> [MetricRecord] {
        let oldest = now.addingTimeInterval(-Double(keepDays) * 86_400)
        var out: [MetricRecord] = []
        for record in held + new where record.end >= oldest {
            out.removeAll { $0.kind == record.kind && $0.begin == record.begin && $0.end == record.end }
            out.append(record)
        }
        return out.sorted { $0.end < $1.end }
    }

    /// The record as one log line: numbers and the app's fixed signpost
    /// names only. A diagnostics record names its hangs and crashes, a
    /// metrics record everything else; each size added after the first
    /// line carries its unit.
    var logLine: String {
        func number(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "-" }
        func fine(_ value: Double?) -> String { value.map { String(format: "%.4f", $0) } ?? "-" }
        func unit(_ value: Double?, _ unit: String) -> String { value.map { String(format: "%.1f", $0) + unit } ?? "-" }
        func exits(_ counts: [String: Int]?) -> String {
            guard let counts else { return "-" }
            return counts.isEmpty ? "0" : counts.keys.sorted().map { "\($0):\(counts[$0] ?? 0)" }.joined(separator: ",")
        }
        // How many, times the mean: 12x0.850s is twelve at 0.850 s each on
        // average.
        func durations(_ value: Durations?) -> String {
            guard let value else { return "-" }
            return value.meanSeconds.map { "\(value.count)x" + String(format: "%.3f", $0) + "s" } ?? "\(value.count)"
        }
        func ratio(_ value: Ratio?) -> String { value.map { String(format: "%.4f", $0.value) + $0.unit } ?? "-" }
        let head = "kind=\(kind.rawValue) hours=\(number(end.timeIntervalSince(begin) / 3_600))"
        if kind == .diagnostics {
            return head + " hangs=\(hangs) crashes=\(crashes)"
        }
        let marks = signposts.keys.sorted().compactMap { name in
            signposts[name].map { "\(name)=\($0.count)/cpu=\(fine($0.cpuSeconds))/mean=\(fine($0.meanSeconds))" }
        }.joined(separator: ",")
        return head + " cpu=\(number(cpuSeconds))"
            + " fg=\(number(foregroundSeconds)) bg=\(number(backgroundSeconds)) peakMB=\(number(peakMemoryMB))"
            + " bgAudio=\(unit(backgroundAudioSeconds, "s"))"
            + " wifiUp=\(unit(wifiUpMB, "MB")) wifiDown=\(unit(wifiDownMB, "MB"))"
            + " cellUp=\(unit(cellularUpMB, "MB")) cellDown=\(unit(cellularDownMB, "MB"))"
            + " writes=\(unit(logicalWritesMB, "MB"))"
            + " hang=\(hangTime.map { String(format: "%.1fs/%d", $0.seconds, $0.count) } ?? "-")"
            + " firstDraw=\(durations(firstDraw)) resume=\(durations(resume))"
            + " scrollHitch=\(ratio(scrollHitch)) hitch=\(ratio(hitch))"
            + " exitsFg=\(exits(foregroundExits)) exitsBg=\(exits(backgroundExits))"
            + " signposts=\(marks.isEmpty ? "-" : marks)"
            + " unfiredOrLost=\(absentSignposts.isEmpty ? "none" : absentSignposts.joined(separator: ","))"
    }

    /// The names the app writes that did not come back in this record, in
    /// the app's order. MetricKit keeps only so many names a day; a name
    /// that went missing shows here instead of silently. The device does
    /// not note which names fired, so a name here either never fired in
    /// the period or fired and was not kept, and the line's word says both.
    var absentSignposts: [String] {
        PerfSignpost.names.filter { signposts[$0] == nil }
    }

    /// The records as the text the measurement page shares: one line each,
    /// newest first, the period's end in UTC before the numbers, so two
    /// devices' texts read the same. A record that is no measurement is
    /// left out.
    static func shareText(_ records: [MetricRecord]) -> String {
        let format = ISO8601DateFormatter()
        return shown(records).sorted { $0.end > $1.end }
            .map { "\(format.string(from: $0.end)) \($0.logLine)" }
            .joined(separator: "\n")
    }
}
