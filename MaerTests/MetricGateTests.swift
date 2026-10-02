// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// MetricKit only in TestFlight and from Xcode, never in the App Store: the
/// gate decides at run time and fails closed; the records stay on the
/// device for two weeks and carry numbers only.
struct MetricGateTests {
    @Test("das Tor: Debug an, Xcode und Sandbox an, Store aus, Unbekanntes aus")
    func theGateFailsClosed() {
        for environment in MetricGate.Environment.allCases {
            #expect(MetricGate.receives(environment: environment, isDebugBuild: true), "a Debug build is on")
        }
        #expect(MetricGate.receives(environment: .xcode, isDebugBuild: false))
        #expect(MetricGate.receives(environment: .sandbox, isDebugBuild: false), "TestFlight installs come from the sandbox")
        #expect(!MetricGate.receives(environment: .production, isDebugBuild: false), "the App Store never measures")
        #expect(!MetricGate.receives(environment: .unknown, isDebugBuild: false), "an unread environment is off")
    }

    static let now = Date(timeIntervalSince1970: 1_759_400_000)
    static func record(_ kind: MetricRecord.Kind = .metrics, daysAgo: Double) -> MetricRecord {
        let end = now.addingTimeInterval(-daysAgo * 86_400)
        return MetricRecord(kind: kind, begin: end.addingTimeInterval(-86_400), end: end, cpuSeconds: 12.5,
                            foregroundSeconds: 600, backgroundSeconds: 1_800, peakMemoryMB: 210,
                            signposts: ["tick": 3_600, "syncRound": 40])
    }

    @Test("zwei Wochen bleiben, aelteres faellt, dieselbe Periode steht einmal, aelteste zuerst")
    func twoWeeksAreKept() {
        let held = [Self.record(daysAgo: 20), Self.record(daysAgo: 13), Self.record(.diagnostics, daysAgo: 13)]
        let kept = MetricRecord.kept(held, adding: [Self.record(daysAgo: 1), Self.record(daysAgo: 13)], now: Self.now)
        #expect(kept.count == 3, "the 20-day record fell, the repeated 13-day record stands once")
        #expect(kept.map(\.end) == kept.map(\.end).sorted())
        #expect(kept.filter { $0.kind == .diagnostics }.count == 1, "the same period of another kind is its own record")
        #expect(MetricRecord.kept([], adding: [Self.record(daysAgo: 14)], now: Self.now).count == 1, "the edge day stays")
    }

    @Test("die Logzeile traegt Zahlen und die festen Signpost-Namen, sonst nichts")
    func theLogLineCarriesNumbers() {
        var record = Self.record(daysAgo: 1)
        record.hangs = 2
        #expect(record.logLine == "kind=metrics hours=24.0 cpu=12.5 fg=600.0 bg=1800.0 peakMB=210.0 hangs=2 crashes=0 signposts=syncRound=40,tick=3600")
        let empty = MetricRecord(kind: .diagnostics, begin: Self.now, end: Self.now)
        #expect(empty.logLine == "kind=diagnostics hours=0.0 cpu=- fg=- bg=- peakMB=- hangs=0 crashes=0 signposts=-")
    }

    @Test("die Ablage behaelt die Eintraege ueber die Naht, ein zweiter Empfang kommt dazu")
    func theLogKeepsThroughTheSeam() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("metric-log-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = MetricLog(ablage: Ablage(directory: directory))
        await log.add([Self.record(daysAgo: 2)], now: Self.now)
        await log.add([Self.record(.diagnostics, daysAgo: 1)], now: Self.now)
        let again = MetricLog(ablage: Ablage(directory: directory))
        #expect(await again.records().map(\.kind) == [.metrics, .diagnostics])
    }

    /// What no behaviour case can see: where the receiver writes, that it
    /// subscribes at one place behind the gate, and that nothing asks the
    /// person to sign in to the App Store.
    @Test("die Naht: nur lokal, eine Anmeldung hinter dem Tor, kein refresh, Start im Haushalt", .needsTheSources)
    func theSeam() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let receiver = try code("Sources/Networking/MetricReceiver.swift")
        #expect(!receiver.contains("URLSession") && !receiver.contains("HTTP."), "the receiver sends nothing")
        let gate = try #require(receiver.range(of: "guard on else { return }"))
        let add = try #require(receiver.range(of: "MXMetricManager.shared.add(shared)"))
        #expect(gate.upperBound <= add.lowerBound, "the subscription stands behind the gate")
        var adds = 0
        var refreshes: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            adds += text.components(separatedBy: "MXMetricManager.shared.add(").count - 1
            if text.contains("AppTransaction.refresh") { refreshes.append(file.lastPathComponent) }
        }
        #expect(adds == 1, "one subscription in the app")
        #expect(refreshes.isEmpty, "a refresh asks the person to sign in: \(refreshes)")
        #expect(try code("Sources/ViewModels/AppHousekeeping.swift").contains("MetricReceiver.startIfAllowed()"))
    }
}
#endif
