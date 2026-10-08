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

    /// An install with a provisioning profile never asks the App Store:
    /// there the read asked the person to sign in at every start. The rule,
    /// the receiver answering Xcode's without the store, and the question
    /// standing before the only read of the transaction.
    @Test("eine Installation mit Profil fragt den Store nie, sie ist die von Xcode", .needsTheSources)
    func anInstallWithAProfileNeverAsksTheStore() async throws {
        #expect(!MetricGate.asksTheStore(carriesProfile: true), "a profile install asked the store")
        #expect(MetricGate.asksTheStore(carriesProfile: false))
        #expect(await MetricReceiver.readEnvironment(carriesProfile: true) == .xcode)
        let receiver = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/MetricReceiver.swift"), encoding: .utf8))
        let question = try #require(receiver.range(of: "MetricGate.asksTheStore(carriesProfile:"))
        let read = try #require(receiver.range(of: "AppTransaction.shared"))
        #expect(question.upperBound <= read.lowerBound, "the transaction is read before the profile was asked")
        #expect(receiver.components(separatedBy: "AppTransaction.shared").count == 2, "one read of the transaction")
    }

    static let now = Date(timeIntervalSince1970: 1_759_400_000)
    static func record(_ kind: MetricRecord.Kind = .metrics, daysAgo: Double) -> MetricRecord {
        let end = now.addingTimeInterval(-daysAgo * 86_400)
        return MetricRecord(kind: kind, begin: end.addingTimeInterval(-86_400), end: end, cpuSeconds: 12.5,
                            foregroundSeconds: 600, backgroundSeconds: 1_800, peakMemoryMB: 210,
                            signposts: ["tick": .init(count: 3_600, cpuSeconds: 12, meanSeconds: 0.0035),
                                        "syncRound": .init(count: 40, cpuSeconds: 3.24, meanSeconds: 0.12)])
    }

    @Test("je Signpost Anzahl, CPU-Zeit und mittlere Dauer aus dem Histogramm; ein Name in zwei Kategorien steht einmal")
    func theSignpostCosts() {
        let mean = MetricRecord.meanSeconds([(start: 0, end: 0.01, count: 3), (start: 0.01, end: 0.03, count: 1)])
        #expect(abs((mean ?? 0) - 0.00875) < 1e-12, "each bucket at its middle: (0.005 * 3 + 0.02) / 4")
        #expect(MetricRecord.meanSeconds([]) == nil && MetricRecord.meanSeconds([(start: 0, end: 1, count: 0)]) == nil)
        let costs = MetricRecord.costs([
            .init(name: "syncRound", count: 30, cpuSeconds: 2, buckets: [(start: 0.25, end: 0.25, count: 30)]),
            .init(name: "syncRound", count: 10, cpuSeconds: 1, buckets: [(start: 0.75, end: 0.75, count: 10)]),
            .init(name: "tick", count: 5, cpuSeconds: nil, buckets: []),
        ])
        #expect(costs["syncRound"] == .init(count: 40, cpuSeconds: 3, meanSeconds: 0.375),
                "counts and CPU add up, the mean is over all buckets: (0.25 * 30 + 0.75 * 10) / 40")
        #expect(costs["tick"] == .init(count: 5, cpuSeconds: nil, meanSeconds: nil), "no CPU and no histogram stay unknown, never zero")
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
        #expect(record.logLine == "kind=metrics hours=24.0 cpu=12.5 fg=600.0 bg=1800.0 peakMB=210.0 hangs=2 crashes=0 signposts=syncRound=40/cpu=3.2400/mean=0.1200,tick=3600/cpu=12.0000/mean=0.0035")
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
        guard case .records(let kept) = await again.records() else {
            Issue.record("the kept records read as unreadable"); return
        }
        #expect(kept.map(\.kind) == [.metrics, .diagnostics])
    }

    /// An unreadable kept file is not "none yet": the page says it was set
    /// aside, and a later delivery of only old records does not write an
    /// empty list over it.
    @Test("eine unlesbare Ablage heisst nicht noch keine; ein leerer Schrieb begraebt sie nicht")
    func anUnreadableLogSaysSo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("metric-log-bad-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent(MetricLog.documentName))
        let log = MetricLog(ablage: Ablage(directory: directory))
        #expect(await log.records() == .unreadable)
        // Only stale records arrive: kept is empty, and the save is refused.
        await log.add([Self.record(daysAgo: 400)], now: Self.now)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(MetricLog.documentName).path),
                "an empty list was written over the unreadable file")
        #expect(await log.records() == .unreadable, "the second read said none yet")
        // A real delivery is a recovery: the page reads records again.
        let fresh = Self.record(daysAgo: 1)
        await log.add([fresh], now: Self.now)
        #expect(await log.records() == .records([fresh]), "the log stayed unreadable after a real delivery")
    }

    @Test("der Empfang abonniert einmal je Prozess", .needsTheSources)
    func theReceiverSubscribesOnce() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/MetricReceiver.swift"), encoding: .utf8))
        let start = try #require(code.range(of: "static func startIfAllowed() async {"))
        let body = code[start.upperBound...].prefix(400)
        #expect(body.contains("guard !started else { return }"), "a second start subscribes again")
    }

    @Test("der geteilte Text: eine Zeile je Eintrag, neueste zuerst, das Ende in UTC vor den Zahlen")
    func theSharedText() {
        let older = Self.record(daysAgo: 3), newer = Self.record(.diagnostics, daysAgo: 1)
        let lines = MetricRecord.shareText([older, newer]).split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines.first?.hasSuffix(newer.logLine) == true && lines.last?.hasSuffix(older.logLine) == true)
        #expect(lines.first?.hasPrefix(ISO8601DateFormatter().string(from: newer.end)) == true)
        #expect(MetricRecord.shareText([]).isEmpty)
    }

    /// The measurement page exists only where the gate opened: the switch
    /// is set behind the gate, and the one entry asks it.
    @Test("die Messseite steht nur hinter dem Tor", .needsTheSources)
    func thePageStandsBehindTheGate() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let receiver = try code("Sources/Networking/MetricReceiver.swift")
        let gate = try #require(receiver.range(of: "guard on else { return }"))
        let set = try #require(receiver.range(of: "isOn = true"))
        #expect(gate.upperBound <= set.lowerBound, "the switch is set behind the gate")
        let diagnostics = try code("Sources/Views/DiagnosticsView.swift")
        let ask = try #require(diagnostics.range(of: "if MetricReceiver.isOn {"))
        let page = try #require(diagnostics.range(of: "MetricRecordsView()"))
        #expect(ask.upperBound <= page.lowerBound, "the entry asks the gate")
        var entries = 0
        for file in ProjectFileIntegrityTests.sourceFiles() {
            entries += SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
                .components(separatedBy: "MetricRecordsView()").count - 1
        }
        #expect(entries == 1, "one way to the page")
    }

    /// The radio's icy-name check costs one more request per play and only
    /// writes a log line, so it runs behind the same gate: never in the App
    /// Store, kept where its log is read.
    @Test("die Radio-Pruefung je Wiedergabe steht hinter dem Tor, an einer Stelle", .needsTheSources)
    func theRadioCheckStandsBehindTheGate() throws {
        let provider = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Providers/RadioProvider.swift"), encoding: .utf8))
        let ask = try #require(provider.range(of: "if MetricReceiver.isOn {"))
        let check = try #require(provider.range(of: "RadioDiagnostics.compareICYName("))
        #expect(ask.upperBound <= check.lowerBound, "the check asks the gate")
        #expect(provider.contains("RADIO icy-check skipped gate=\\(MetricReceiver.decision.rawValue"),
                "a play without the check is silent, or does not say whether the gate is closed or undecided")
        // The play never waits for the gate: nothing in the play path asks
        // for the environment or awaits the receiver.
        let play = try #require(provider.range(of: "func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {"))
        let playBody = provider[play.upperBound...].prefix(2_400)
        #expect(!playBody.contains("startIfAllowed") && !playBody.contains("await MetricReceiver"),
                "a play waits for the gate")
        // The decision is undecided until the start reads the environment,
        // and set before the gate turns anything on.
        let receiver = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/MetricReceiver.swift"), encoding: .utf8))
        #expect(receiver.contains("static var decision: MetricGate.Decision = .undecided"))
        let decided = try #require(receiver.range(of: "decision = on ? .open : .closed"))
        let gate = try #require(receiver.range(of: "guard on else { return }"))
        #expect(decided.upperBound <= gate.lowerBound, "a closed gate never says so")
        #expect(MetricGate.Decision.allCases.map(\.rawValue) == ["undecided", "open", "closed"], "the words the line names")
        var calls = 0
        for file in ProjectFileIntegrityTests.sourceFiles() {
            calls += SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
                .components(separatedBy: "RadioDiagnostics.compareICYName(").count - 1
        }
        #expect(calls == 1, "one place starts the check")
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
