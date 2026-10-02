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
    /// names only.
    var logLine: String {
        func number(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "-" }
        func fine(_ value: Double?) -> String { value.map { String(format: "%.4f", $0) } ?? "-" }
        let marks = signposts.keys.sorted().compactMap { name in
            signposts[name].map { "\(name)=\($0.count)/cpu=\(number($0.cpuSeconds))/mean=\(fine($0.meanSeconds))" }
        }.joined(separator: ",")
        return "kind=\(kind.rawValue) hours=\(number(end.timeIntervalSince(begin) / 3_600)) cpu=\(number(cpuSeconds))"
            + " fg=\(number(foregroundSeconds)) bg=\(number(backgroundSeconds)) peakMB=\(number(peakMemoryMB))"
            + " hangs=\(hangs) crashes=\(crashes) signposts=\(marks.isEmpty ? "-" : marks)"
    }

    /// The records as the text the measurement page shares: one line each,
    /// newest first, the period's end in UTC before the numbers, so two
    /// devices' texts read the same.
    static func shareText(_ records: [MetricRecord]) -> String {
        let format = ISO8601DateFormatter()
        return records.sorted { $0.end > $1.end }
            .map { "\(format.string(from: $0.end)) \($0.logLine)" }
            .joined(separator: "\n")
    }
}
