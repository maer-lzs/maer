// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import MetricKit
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

    /// What a signpost wrote to disk, where MetricKit gives it: a name in
    /// two categories adds its writes, a reading without them adds nothing,
    /// a name with none stays unknown and shows as "-", never 0.
    @Test("je Signpost die Schreibmenge in MB, wo MetricKit sie gibt, sonst unbekannt, nie null; mit Einheit in Zeile und Text")
    func theSignpostWritesCarryTheirUnit() throws {
        let costs = MetricRecord.costs([
            .init(name: "syncRound", count: 30, cpuSeconds: 2, buckets: [], writesMB: 1.25),
            .init(name: "syncRound", count: 10, cpuSeconds: 1, buckets: [], writesMB: 0.5),
            .init(name: "syncRound", count: 2, cpuSeconds: nil, buckets: []),
            .init(name: "tick", count: 5, cpuSeconds: nil, buckets: []),
        ])
        #expect(costs["syncRound"]?.writesMB == 1.75, "both categories add up, the one without writes adds nothing")
        #expect(costs["tick"]?.writesMB == nil, "no writes given stay unknown")
        var record = Self.record(daysAgo: 1)
        record.signposts = costs
        #expect(record.logLine.contains("signposts=syncRound=42/cpu=3.0000/mean=-/writes=1.7500MB,tick=5/cpu=-/mean=-/writes=- "),
                "\(record.logLine)")
        #expect(MetricRecord.shareText([record]).contains("/writes=1.7500MB,"))
        // Kept and read again, the writes stay.
        let again = try JSONDecoder().decode(MetricRecord.self, from: JSONEncoder().encode(record))
        #expect(again.signposts["syncRound"]?.writesMB == 1.75 && again.signposts["tick"]?.writesMB == nil)
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
        let record = Self.record(daysAgo: 1)
        #expect(record.logLine == "kind=metrics hours=24.0 cpu=12.5 fg=600.0 bg=1800.0 peakMB=210.0 bgAudio=- wifiUp=- wifiDown=- cellUp=- cellDown=- writes=- hang=- firstDraw=- resume=- scrollHitch=- hitch=- exitsFg=- exitsBg=- signposts=syncRound=40/cpu=3.2400/mean=0.1200/writes=-,tick=3600/cpu=12.0000/mean=0.0035/writes=- unfiredOrLost=nowPlaying,statsMerge,syncLoop,syncRoundOf,standMerge,standMergeOf,feedParse,thumb-hit,decode,originalCached,downloadedEntries-recompute,standingRead,accessRead,barCollapsedFlip,walkPositions,walkRetiredChoices,walkChoices")
    }

    /// MetricKit keeps only so many signpost names a day, a limit not
    /// measured here. Each record names the app's names that did not come
    /// back, so a missing one is seen, not silent. The device does not
    /// note what fired, so the word says both readings: never fired in the
    /// period, or fired and not kept.
    @Test("der Satz nennt die Signpost-Namen, die nicht kamen, und sagt, dass sie nicht feuerten oder verloren gingen")
    func aRecordNamesTheSignpostsThatDidNotCome() {
        var record = Self.record(daysAgo: 1)
        record.signposts = Dictionary(uniqueKeysWithValues: PerfSignpost.names.map { ($0, .init(count: 1)) })
        #expect(record.absentSignposts.isEmpty && record.logLine.hasSuffix(" unfiredOrLost=none"))
        record.signposts["feedParse"] = nil
        record.signposts["tick"] = nil
        #expect(record.absentSignposts == ["tick", "feedParse"], "the app's order")
        #expect(record.logLine.hasSuffix(" unfiredOrLost=tick,feedParse"))
        #expect(MetricRecord.shareText([record]).hasSuffix(" unfiredOrLost=tick,feedParse"), "the shared text names them too")
    }

    /// The launch to the first frame and the return to the app, each as
    /// how many times the mean; the hitch ratios with the unit MetricKit
    /// handed over, its spaces taken out.
    @Test("Start, Rueckkehr und Hitch stehen mit Einheit in der Zeile")
    func launchAndHitchCarryTheirUnits() {
        let draws = MetricRecord.durations([(start: 0.5, end: 1, count: 3), (start: 1, end: 2, count: 1)])
        #expect(draws == .init(count: 4, meanSeconds: 0.9375), "each bucket at its middle: (0.75 * 3 + 1.5) / 4")
        #expect(MetricRecord.durations([]) == .init(count: 0, meanSeconds: nil), "none counted has no mean")
        #expect(MetricRecord.ratio(5, symbol: "ms per s") == .init(value: 5, unit: "mspers"))
        var record = Self.record(daysAgo: 1)
        record.signposts = [:]
        record.firstDraw = draws
        record.resume = .init(count: 0, meanSeconds: nil)
        record.scrollHitch = MetricRecord.ratio(2.5, symbol: "ms per s")
        #expect(record.logLine.contains(" hang=- firstDraw=4x0.938s resume=0 scrollHitch=2.5000mspers hitch=- exitsFg=-"),
                "\(record.logLine)")
        #expect(record.isMeasurement && MetricRecord.shareText([record]).contains(" firstDraw=4x0.938s "))
    }

    /// Hangs and crashes are what a diagnostics payload counts. A metrics
    /// record does not measure them, so its line never says 0 for them;
    /// a diagnostics record names nothing else.
    @Test("hangs und crashes stehen nur im Diagnose-Satz")
    func hangsAndCrashesOnlyInDiagnostics() {
        var metrics = Self.record(daysAgo: 1)
        metrics.hangs = 2
        #expect(!metrics.logLine.contains("hangs=") && !metrics.logLine.contains("crashes="))
        let diagnostics = MetricRecord(kind: .diagnostics, begin: Self.now, end: Self.now, hangs: 1, crashes: 2)
        #expect(diagnostics.logLine == "kind=diagnostics hours=0.0 hangs=1 crashes=2")
    }

    /// Background audio, the network, the disk, the hang time and the
    /// exits: each with its unit, an unknown as "-", a counted zero as 0.
    @Test("jede neue Groesse steht mit Einheit in der Zeile")
    func theNewSizesCarryTheirUnits() {
        var record = Self.record(daysAgo: 1)
        record.signposts = [:]
        record.backgroundAudioSeconds = 3_600
        record.wifiUpMB = 1.2
        record.wifiDownMB = 310
        record.cellularUpMB = 0
        record.cellularDownMB = 42.5
        record.logicalWritesMB = 18
        record.hangTime = .init(count: 3, seconds: 1.5)
        record.foregroundExits = ["memLimit": 1, "abnormal": 2]
        record.backgroundExits = [:]
        #expect(record.logLine == "kind=metrics hours=24.0 cpu=12.5 fg=600.0 bg=1800.0 peakMB=210.0 bgAudio=3600.0s wifiUp=1.2MB wifiDown=310.0MB cellUp=0.0MB cellDown=42.5MB writes=18.0MB hang=1.5s/3 firstDraw=- resume=- scrollHitch=- hitch=- exitsFg=abnormal:2,memLimit:1 exitsBg=0 signposts=- unfiredOrLost=" + PerfSignpost.names.joined(separator: ","))
    }

    @Test("Beendigungen nur mit Zahl; die Hangzeit aus dem Histogramm, ohne Klasse eine gemessene Null")
    func exitsAndHangTime() {
        #expect(MetricRecord.exits(["normal": 0, "memPressure": 4, "memLimit": 0, "watchdog": 1]) == ["memPressure": 4, "watchdog": 1])
        #expect(MetricRecord.exits(["normal": 0]).isEmpty, "nothing counted is an empty list, not unknown")
        let hang = MetricRecord.hangTime([(start: 0.25, end: 0.75, count: 2), (start: 1, end: 3, count: 1)])
        #expect(hang == .init(count: 3, seconds: 3), "each bucket at its middle: 0.5 * 2 + 2 * 1")
        #expect(MetricRecord.hangTime([]) == .init(count: 0, seconds: 0))
    }

    /// The week's four empty records (hours=0.0, no number) are no
    /// measurement: neither the page nor its text shows them.
    @Test("ein Satz ohne Zeitraum und ohne Zahl ist keine Messung")
    func aRecordWithoutPeriodOrNumberIsNotShown() {
        let empty = MetricRecord(kind: .diagnostics, begin: Self.now, end: Self.now)
        let instant = MetricRecord(kind: .diagnostics, begin: Self.now, end: Self.now, hangs: 1)
        var silentDay = MetricRecord(kind: .metrics, begin: Self.now.addingTimeInterval(-86_400), end: Self.now)
        silentDay.peakMemoryMB = nil
        let full = Self.record(daysAgo: 1)
        #expect(!empty.isMeasurement)
        #expect(instant.isMeasurement, "a hang without a period is a number")
        #expect(silentDay.isMeasurement, "a period without a number is a period")
        var launchOnly = empty
        launchOnly.firstDraw = .init(count: 1, meanSeconds: 0.4)
        #expect(launchOnly.isMeasurement, "a launch without a period is a number")
        #expect(MetricRecord.shown([empty, full, instant]) == [full, instant])
        #expect(MetricRecord.shareText([empty]).isEmpty, "the text names an empty record")
    }

    /// The page takes the same rule as the shared text: what it lists is
    /// what `shown` keeps.
    @Test("die Messseite zeigt nur Messungen", .needsTheSources)
    func thePageShowsOnlyMeasurements() throws {
        let page = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/MetricRecordsView.swift"), encoding: .utf8))
        #expect(page.contains("records = MetricRecord.shown(kept)"), "the page lists records that are no measurement")
    }

    /// The records already on a device were written before the new sizes
    /// existed; they read, and what they did not carry stays unknown.
    @Test("ein alter Satz bleibt lesbar, was er nicht trug, bleibt unbekannt")
    func anOldRecordStaysReadable() throws {
        let old = #"[{"kind":"metrics","begin":781092800,"end":781179200,"cpuSeconds":182,"foregroundSeconds":64,"backgroundSeconds":3600,"peakMemoryMB":726,"hangs":0,"crashes":0,"signposts":{"tick":{"count":64,"cpuSeconds":1.5,"meanSeconds":0.002}}},{"kind":"diagnostics","begin":781179200,"end":781179200,"hangs":1,"crashes":0,"signposts":{}}]"#
        let records = try JSONDecoder().decode([MetricRecord].self, from: Data(old.utf8))
        #expect(records.count == 2)
        let metrics = try #require(records.first)
        #expect(metrics.peakMemoryMB == 726 && metrics.signposts["tick"]?.count == 64)
        #expect(metrics.signposts["tick"]?.writesMB == nil && metrics.logLine.contains("tick=64/cpu=1.5000/mean=0.0020/writes=-"),
                "a signpost kept before its writes were read shows them as unknown")
        #expect(metrics.backgroundAudioSeconds == nil && metrics.wifiUpMB == nil && metrics.logicalWritesMB == nil
                && metrics.hangTime == nil && metrics.foregroundExits == nil)
        #expect(metrics.firstDraw == nil && metrics.resume == nil && metrics.scrollHitch == nil && metrics.hitch == nil)
        #expect(metrics.logLine.contains("bgAudio=- wifiUp=-"))
        #expect(metrics.logLine.contains(" firstDraw=- resume=- scrollHitch=- hitch=- "))
        #expect(records.last?.logLine == "kind=diagnostics hours=0.0 hangs=1 crashes=0")
    }

    /// The groups of a payload MetricKit hands over and the receiver does
    /// not read, each with why. A group nobody reads and nobody excepted is
    /// a size lost by accident; an exception for a group that is read is a
    /// reason that no longer holds. Each entry names the major iOS version
    /// from which the runtime carries its group: the app runs from iOS 18,
    /// and a runtime before that version has no such group to except.
    static let unreadGroups: [String: (since: Int, reason: String)] = [
        "gpuMetrics": (18, "an audio player draws little of its own on the GPU; the measuring plan asks for CPU, not GPU time"),
        "cellularConditionMetrics": (18, "the signal bars of the network say how the cell was, not what the app did"),
        "locationActivityMetrics": (18, "the app asks for no location"),
        "displayMetrics": (18, "the mean pixel luminance of an OLED screen; the plan does not ask about the screen"),
        // The header of SDK 27.0 has it from iOS 26.0.
        "diskSpaceUsageMetrics": (26, "the space the app takes on disk; the plan measures what it writes, which diskIOMetrics carries"),
        // The runtime of iOS 27.0 carries these three and 18.6 does not;
        // 26 is not measured. The header of SDK 27.0 declares none of them,
        // so there is no public type to read.
        "intervalMetrics": (27, "in the runtime, not in the SDK's header: no public type to read it"),
        "metalFrameRateMetrics": (27, "in the runtime, not in the SDK's header: no public type to read it"),
        "stateMetrics": (27, "in the runtime, not in the SDK's header: no public type to read it"),
    ]

    /// The sizes inside a read group that the receiver does not read, each
    /// with why, as `Type.size` with the version as for the groups. Measured
    /// by the walk below on the runtimes of iOS 27.0 and 18.6.
    static let unreadSizes: [String: (since: Int, reason: String)] = [
        "MXForegroundExitData.cumulativeCPUResourceLimitExitCount": (18, runtimeOnly),
        "MXBackgroundExitData.cumulativeBackgroundFetchCompletionTimeoutExitCount": (18, runtimeOnly),
        "MXBackgroundExitData.cumulativeBackgroundURLSessionCompletionTimeoutExitCount": (18, runtimeOnly),
        "MXAppLaunchMetric.histogrammedExtendedLaunch": (18, "the app never extends a launch measurement, so the histogram stays empty"),
        "MXAppLaunchMetric.histogrammedOptimizedTimeToFirstDraw": (18, "a second first draw histogram, for the launches the system optimized; the record keeps one launch number"),
        "MXAppRunTimeMetric.cumulativeBackgroundLocationTime": (18, "the app asks for no location"),
        "MXCPUMetric.cumulativeCPUInstructions": (18, "the measuring plan asks for CPU time; instructions count the same work in another unit"),
        "MXMemoryMetric.averageSuspendedMemory": (18, "the measuring plan asks for the peak of memory"),
        "MXSignpostMetric.signpostCategory": (18, "each written name stands once across the categories, so the name alone says which"),
        "MXSignpostIntervalData.averageMemory": (18, "per signpost the plan asks for time and CPU; memory is read for the whole period"),
        "MXSignpostIntervalData.cumulativeHitchTimeRatio": (18, "no signpost of the app marks an animation"),
        // The runtime of iOS 27.0 carries these and 18.6 does not; 26 is
        // not measured.
        "MXAnimationMetric.totalAnimationTime": (27, runtimeOnly),
        "MXAnimationMetric.totalHitchTime": (27, runtimeOnly),
        "MXAnimationMetric.totalScrollHitchTime": (27, runtimeOnly),
        "MXAnimationMetric.totalScrollTime": (27, runtimeOnly),
        "MXSignpostIntervalData.totalAnimationTime": (27, runtimeOnly),
        "MXSignpostIntervalData.totalHitchTime": (27, runtimeOnly),
    ]
    static let runtimeOnly = "in the runtime, not in the SDK's header: no public symbol to read it"

    /// What a type carries besides its sizes: a formatter is no measurement.
    static let notSizes: Set = ["MXSignpostIntervalData.measurementFormatter"]

    /// The runtime says only `NSArray` for a list; what it lists is named
    /// here.
    static let elementTypes = ["signpostMetrics": "MXSignpostMetric"]

    /// Types whose properties are one measurement each, not sizes to walk.
    static let leafTypes: Set = ["MXHistogram", "MXAverage"]

    /// A type's own properties as the runtime has them, without those of
    /// its superclasses, each with the class it holds when it holds one.
    static func ownProperties(_ type: AnyClass) -> [String: String?] {
        func properties(_ type: AnyClass) -> [String: String?] {
            var count: UInt32 = 0
            guard let list = class_copyPropertyList(type, &count) else { return [:] }
            defer { free(list) }
            return Dictionary((0..<Int(count)).map { index -> (String, String?) in
                // `T@"MXCPUMetric"` for an object, `TQ` for a count.
                let attribute = String(cString: property_getAttributes(list[index])!)
                let held = attribute.split(separator: ",").first.flatMap { type -> String? in
                    guard type.hasPrefix("T@\"") else { return nil }
                    return String(type.dropFirst(3).prefix { $0 != "\"" && $0 != "<" })
                }
                return (String(cString: property_getName(list[index])), held)
            }, uniquingKeysWith: { first, _ in first })
        }
        var inherited = Set<String>()
        var parent: AnyClass? = class_getSuperclass(type)
        while let next = parent {
            inherited.formUnion(properties(next).keys)
            parent = class_getSuperclass(next)
        }
        return properties(type).filter { !inherited.contains($0.key) }
    }

    /// The properties of `MXMetricPayload` as the runtime has them, without
    /// NSObject's and without the frame (period, version, metadata): what is
    /// left are the groups.
    static func payloadGroups() -> (groups: Set<String>, frameFound: Bool) {
        let frame: Set = ["latestApplicationVersion", "includesMultipleApplicationVersions", "timeStampBegin",
                          "timeStampEnd", "metaData"]
        let all = Set(ownProperties(MXMetricPayload.self).keys)
        return (all.subtracting(frame), frame.isSubset(of: all))
    }

    /// The body of the function in `source` that takes `type`, found by
    /// its parameter (`: Type)`, `: Type?)` or `: [Type])`), or nil.
    static func body(in source: String, takingA type: String) -> Substring? {
        guard let head = source.range(of: #"func [^{]*: \[?"# + type + #"\]?\??\)"#, options: .regularExpression),
              let open = source[head.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        for index in source[open...].indices {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" { depth -= 1; if depth == 0 { return source[open...index] } }
        }
        return nil
    }

    /// Every size the runtime carries below `groups`, as `Type.size`, with
    /// the type whose function reads it: the type itself when the receiver
    /// has a function that takes it, else the nearest above it, at the top
    /// the payload. What the walk cannot enter is returned apart: a group
    /// that holds no object, a list without a named element type, a type
    /// the runtime does not resolve.
    static func sizes(below groups: Set<String>, in receiver: String) -> (sizes: [String: String], unwalked: [String]) {
        var found: [String: String] = [:]
        var unwalked: [String] = []
        func walk(_ typeName: String, reader: String) {
            guard let type = NSClassFromString(typeName) else {
                unwalked.append(typeName)
                return
            }
            let reader = body(in: receiver, takingA: typeName) == nil ? reader : typeName
            for (name, held) in ownProperties(type) {
                if let held, held.hasPrefix("MX"), !leafTypes.contains(held) {
                    walk(held, reader: reader)
                } else {
                    found["\(typeName).\(name)"] = reader
                }
            }
        }
        let payload = ownProperties(MXMetricPayload.self)
        for group in groups.sorted() {
            switch payload[group] ?? nil {
            case "NSArray":
                if let element = elementTypes[group] { walk(element, reader: "MXMetricPayload") } else { unwalked.append(group) }
            case let held?:
                walk(held, reader: "MXMetricPayload")
            case nil:
                unwalked.append(group)
            }
        }
        return (found, unwalked)
    }

    /// Which entries of `table` a runtime of this major version must find,
    /// and which it must not: an entry from a later version names what this
    /// runtime does not carry yet.
    static func expectedExceptions(_ table: [String: (since: Int, reason: String)] = unreadGroups,
                                   onMajor major: Int) -> (due: Set<String>, notYet: Set<String>) {
        let due = Set(table.filter { $0.value.since <= major }.keys)
        return (due, Set(table.keys).subtracting(due))
    }

    @Test("jede Gruppe der Nutzlast hat einen Leser oder eine Ausnahme mit Grund, nie beides, je Laufzeit", .needsTheSources)
    func everyGroupOfThePayloadIsReadOrExcepted() throws {
        let receiver = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/MetricReceiver.swift"), encoding: .utf8))
        let (groups, frameFound) = Self.payloadGroups()
        try #require(frameFound && groups.contains("cpuMetrics"), "the payload's properties were not read: \(groups)")
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let (due, notYet) = Self.expectedExceptions(onMajor: major)
        let read = groups.filter { receiver.contains("payload.\($0)") }
        let unread = groups.subtracting(read)
        #expect(unread.subtracting(due).sorted() == [], "a group nobody reads and nobody excepted on iOS \(major)")
        // Whether a group is read is the source's, on every runtime.
        #expect(Self.unreadGroups.keys.filter { receiver.contains("payload.\($0)") }.sorted() == [],
                "an exception for a group that is read")
        #expect(due.subtracting(groups).sorted() == [], "an exception names no group of the payload on iOS \(major)")
        #expect(notYet.intersection(groups).sorted() == [], "a group came before the version its entry names, on iOS \(major)")
        #expect(Self.unreadGroups.values.allSatisfy { !$0.reason.isEmpty && $0.since >= 18 }, "an exception without a reason")
        #expect(read.isSuperset(of: ["applicationLaunchMetrics", "animationMetrics"]), "launch and hitch are read")
    }

    /// One level below the groups: inside each group the receiver reads,
    /// every size the runtime carries is read or excepted with a reason,
    /// never both. A size counts as read when its name follows a dot in the
    /// function that reads its type, so the same name in two types (the
    /// exit counts of front and back, the writes of the disk and of a
    /// signpost) is judged in its own function. What the walk does not see:
    /// a size read in that function from another type of the same name.
    @Test("je gelesene Gruppe ist jede Groesse, die die Laufzeit traegt, gelesen oder mit Grund ausgenommen, nie beides, je Laufzeit", .needsTheSources)
    func everySizeOfAReadGroupIsReadOrExcepted() throws {
        let receiver = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/MetricReceiver.swift"), encoding: .utf8))
        let readGroups = Self.payloadGroups().groups.filter { receiver.contains("payload.\($0)") }
        let (sizes, unwalked) = Self.sizes(below: readGroups, in: receiver)
        try #require(sizes["MXCPUMetric.cumulativeCPUTime"] == "MXMetricPayload"
                     && sizes["MXSignpostIntervalData.cumulativeCPUTime"] == "MXSignpostMetric",
                     "the sizes were not walked: \(sizes.count)")
        #expect(unwalked == [], "a read group, list or type the walk could not enter")
        let read = Set(sizes.filter { key, reader in
            guard let body = Self.body(in: receiver, takingA: reader),
                  let size = key.split(separator: ".").last else { return false }
            // `.hitchTimeRatio` reads, and `.scrollHitchTimeRatio` does not
            // read it; a longer name after it is another size.
            return body.ranges(of: "." + size).contains { found in
                found.upperBound == body.endIndex
                    || !(body[found.upperBound].isLetter || body[found.upperBound].isNumber || body[found.upperBound] == "_")
            }
        }.keys)
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let (due, notYet) = Self.expectedExceptions(Self.unreadSizes, onMajor: major)
        let unread = Set(sizes.keys).subtracting(read).subtracting(Self.notSizes)
        #expect(unread.subtracting(due).sorted() == [], "a size nobody reads and nobody excepted on iOS \(major)")
        #expect(read.intersection(Self.unreadSizes.keys).sorted() == [], "an exception for a size that is read")
        #expect(due.subtracting(sizes.keys).sorted() == [], "an exception names no size of the runtime on iOS \(major)")
        #expect(notYet.intersection(sizes.keys).sorted() == [], "a size came before the version its entry names, on iOS \(major)")
        #expect(Self.notSizes.subtracting(sizes.keys).sorted() == [], "a type carries no such formatter")
        #expect(Self.unreadSizes.values.allSatisfy { !$0.reason.isEmpty && $0.since >= 18 }, "an exception without a reason")
    }

    /// The split by version, without a runtime: on 18 only the old four
    /// groups are due, on 26 the disk space joins, on 27 all eight; of the
    /// sizes eleven from 18 and six more from 27.
    @Test("die Ausnahmen je Laufzeit: 18, 26 und 27")
    func theExceptionsByRuntime() {
        let old: Set = ["gpuMetrics", "cellularConditionMetrics", "locationActivityMetrics", "displayMetrics"]
        #expect(Self.expectedExceptions(onMajor: 18).due == old)
        #expect(Self.expectedExceptions(onMajor: 26).due == old.union(["diskSpaceUsageMetrics"]))
        #expect(Self.expectedExceptions(onMajor: 27).due == Set(Self.unreadGroups.keys))
        #expect(Self.expectedExceptions(onMajor: 18).notYet.count == 4)
        #expect(Self.expectedExceptions(Self.unreadSizes, onMajor: 18).due.count == 11)
        #expect(Self.expectedExceptions(Self.unreadSizes, onMajor: 26).due.count == 11)
        #expect(Self.expectedExceptions(Self.unreadSizes, onMajor: 27).due == Set(Self.unreadSizes.keys))
        #expect(Self.expectedExceptions(Self.unreadSizes, onMajor: 18).notYet.count == 6)
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
