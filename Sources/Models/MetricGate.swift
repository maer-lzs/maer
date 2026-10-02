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
    /// Interval count per signpost name in the period.
    var signposts: [String: Int] = [:]

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
        let marks = signposts.keys.sorted().map { "\($0)=\(signposts[$0] ?? 0)" }.joined(separator: ",")
        return "kind=\(kind.rawValue) hours=\(number(end.timeIntervalSince(begin) / 3_600)) cpu=\(number(cpuSeconds))"
            + " fg=\(number(foregroundSeconds)) bg=\(number(backgroundSeconds)) peakMB=\(number(peakMemoryMB))"
            + " hangs=\(hangs) crashes=\(crashes) signposts=\(marks.isEmpty ? "-" : marks)"
    }
}
