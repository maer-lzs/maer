// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import MetricKit
import OSLog
import StoreKit

/// Receives MetricKit's daily payloads and diagnostics and keeps a short
/// record of each on this device. Nothing is sent anywhere. It subscribes
/// only where `MetricGate` lets it: a build from Xcode and TestFlight, never
/// the App Store. The iOS 27.0 SDK marks `MXMetricManager` as to be
/// deprecated in favour of `MetricManager`; this receiver stays on the
/// older surface, which the app's minimum target (iOS 18) has.
final class MetricReceiver: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricReceiver(log: MetricLog(ablage: MetricLog.defaultAblage))

    nonisolated let log: MetricLog

    /// Whether this run receives payloads: what the gate said at start. The
    /// measurement page exists only while it is true, so an install from
    /// the App Store never shows it; the radio's check of a station's own
    /// name on each play runs only while it is true, too.
    private(set) static var isOn = false
    /// What the gate has said so far: undecided until the start has read
    /// the environment, then open or closed.
    private(set) static var decision: MetricGate.Decision = .undecided

    init(log: MetricLog) {
        self.log = log
    }

    /// Reads the environment once and subscribes when the gate is open. A
    /// Debug build never asks the App Store: it is on either way. The log
    /// line says what was read, so the first TestFlight build shows how
    /// TestFlight reports itself.
    static func startIfAllowed() async {
        // Once per process: the task that calls this can run again, and a
        // second subscription doubled every log line.
        guard !started else { return }
        started = true
        #if DEBUG
        let isDebugBuild = true
        let environment = MetricGate.Environment.unknown
        #else
        let isDebugBuild = false
        let environment = await readEnvironment()
        #endif
        let on = MetricGate.receives(environment: environment, isDebugBuild: isDebugBuild)
        Logger.library.notice("METRICS gate environment=\(environment.rawValue, privacy: .public) debug=\(isDebugBuild) on=\(on)")
        decision = on ? .open : .closed
        guard on else { return }
        isOn = true
        PerfSignpost.measure()
        MXMetricManager.shared.add(shared)
    }

    /// The kept records, for the measurement page.
    static func records() async -> MetricLog.Reading {
        await shared.log.records()
    }
    private static var started = false

    /// The environment that signed this install. An install with a
    /// provisioning profile is Xcode's and the App Store is not asked
    /// (`MetricGate.asksTheStore`): there `AppTransaction.shared` asked the
    /// person to sign in at every start. TestFlight and App Store installs
    /// carry no profile and are asked; whether the system asks for a
    /// sign-in there is not measured. It throws when nothing is there.
    static func readEnvironment(
        carriesProfile: Bool = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") != nil
    ) async -> MetricGate.Environment {
        guard MetricGate.asksTheStore(carriesProfile: carriesProfile) else { return .xcode }
        do {
            let transaction: AppTransaction
            switch try await AppTransaction.shared {
            case .verified(let value), .unverified(let value, _): transaction = value
            }
            switch transaction.environment {
            case .xcode: return .xcode
            case .sandbox: return .sandbox
            case .production: return .production
            default: return .unknown
            }
        } catch {
            Logger.library.notice("METRICS environment unread: \(FailureReason.of(error), privacy: .public)")
            return .unknown
        }
    }

    /// One signpost's numbers from MetricKit's types, the histogram's edges
    /// in seconds.
    nonisolated static func reading(of metric: MXSignpostMetric) -> MetricRecord.SignpostReading {
        let data = metric.signpostIntervalData
        return MetricRecord.SignpostReading(name: metric.signpostName, count: metric.totalCount,
                                            cpuSeconds: data?.cumulativeCPUTime?.converted(to: .seconds).value,
                                            buckets: buckets(of: data?.histogrammedSignpostDuration))
    }

    /// A duration histogram's buckets, the edges in seconds.
    nonisolated static func buckets(of histogram: MXHistogram<UnitDuration>?) -> [(start: Double, end: Double, count: Int)] {
        (histogram?.bucketEnumerator.allObjects ?? [])
            .compactMap { $0 as? MXHistogramBucket<UnitDuration> }
            .map { (start: $0.bucketStart.converted(to: .seconds).value,
                    end: $0.bucketEnd.converted(to: .seconds).value,
                    count: $0.bucketCount) }
    }

    /// The exits of one period by reason, foreground and background.
    nonisolated static func exits(of metric: MXAppExitMetric) -> (foreground: [String: Int], background: [String: Int]) {
        let front = metric.foregroundExitData, back = metric.backgroundExitData
        return (MetricRecord.exits(["normal": front.cumulativeNormalAppExitCount,
                                    "memLimit": front.cumulativeMemoryResourceLimitExitCount,
                                    "badAccess": front.cumulativeBadAccessExitCount,
                                    "abnormal": front.cumulativeAbnormalExitCount,
                                    "illegal": front.cumulativeIllegalInstructionExitCount,
                                    "watchdog": front.cumulativeAppWatchdogExitCount]),
                MetricRecord.exits(["normal": back.cumulativeNormalAppExitCount,
                                    "memLimit": back.cumulativeMemoryResourceLimitExitCount,
                                    "memPressure": back.cumulativeMemoryPressureExitCount,
                                    "cpuLimit": back.cumulativeCPUResourceLimitExitCount,
                                    "badAccess": back.cumulativeBadAccessExitCount,
                                    "abnormal": back.cumulativeAbnormalExitCount,
                                    "illegal": back.cumulativeIllegalInstructionExitCount,
                                    "watchdog": back.cumulativeAppWatchdogExitCount,
                                    "lockedFile": back.cumulativeSuspendedWithLockedFileExitCount,
                                    "taskTimeout": back.cumulativeBackgroundTaskAssertionTimeoutExitCount]))
    }

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        let records = payloads.map { payload in
            let network = payload.networkTransferMetrics
            let exits = payload.applicationExitMetrics.map(Self.exits(of:))
            let launch = payload.applicationLaunchMetrics
            let animation = payload.animationMetrics
            var hitch: MetricRecord.Ratio?
            if #available(iOS 26.0, *), let ratio = animation?.hitchTimeRatio {
                hitch = MetricRecord.ratio(ratio.value, symbol: ratio.unit.symbol)
            }
            return MetricRecord(kind: .metrics, begin: payload.timeStampBegin, end: payload.timeStampEnd,
                                cpuSeconds: payload.cpuMetrics?.cumulativeCPUTime.converted(to: .seconds).value,
                                foregroundSeconds: payload.applicationTimeMetrics?.cumulativeForegroundTime.converted(to: .seconds).value,
                                backgroundSeconds: payload.applicationTimeMetrics?.cumulativeBackgroundTime.converted(to: .seconds).value,
                                peakMemoryMB: payload.memoryMetrics?.peakMemoryUsage.converted(to: .megabytes).value,
                                backgroundAudioSeconds: payload.applicationTimeMetrics?.cumulativeBackgroundAudioTime.converted(to: .seconds).value,
                                wifiUpMB: network?.cumulativeWifiUpload.converted(to: .megabytes).value,
                                wifiDownMB: network?.cumulativeWifiDownload.converted(to: .megabytes).value,
                                cellularUpMB: network?.cumulativeCellularUpload.converted(to: .megabytes).value,
                                cellularDownMB: network?.cumulativeCellularDownload.converted(to: .megabytes).value,
                                logicalWritesMB: payload.diskIOMetrics?.cumulativeLogicalWrites.converted(to: .megabytes).value,
                                hangTime: payload.applicationResponsivenessMetrics.map {
                                    MetricRecord.hangTime(Self.buckets(of: $0.histogrammedApplicationHangTime))
                                },
                                firstDraw: launch.map { MetricRecord.durations(Self.buckets(of: $0.histogrammedTimeToFirstDraw)) },
                                resume: launch.map { MetricRecord.durations(Self.buckets(of: $0.histogrammedApplicationResumeTime)) },
                                scrollHitch: animation.map {
                                    MetricRecord.ratio($0.scrollHitchTimeRatio.value, symbol: $0.scrollHitchTimeRatio.unit.symbol)
                                },
                                hitch: hitch,
                                foregroundExits: exits?.foreground, backgroundExits: exits?.background,
                                signposts: MetricRecord.costs((payload.signpostMetrics ?? []).map(Self.reading(of:))))
        }
        let log = self.log
        // MetricKit calls on a queue of its own; the log is an actor.
        Task { await log.add(records) }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let records = payloads.map { payload in
            MetricRecord(kind: .diagnostics, begin: payload.timeStampBegin, end: payload.timeStampEnd,
                         hangs: payload.hangDiagnostics?.count ?? 0, crashes: payload.crashDiagnostics?.count ?? 0)
        }
        let log = self.log
        // MetricKit calls on a queue of its own; the log is an actor.
        Task { await log.add(records) }
    }
}

/// The kept records, one document through the seam, in Application
/// Support so they never reach a backup of the person's documents.
actor MetricLog {
    static let documentName = "metric-records.json"
    static var defaultAblage: Ablage {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Ablage(directory: support.appendingPathComponent("metrics", isDirectory: true))
    }

    private let ablage: Ablage

    init(ablage: Ablage) {
        self.ablage = ablage
    }

    func add(_ new: [MetricRecord], now: Date = Date()) async {
        guard !new.isEmpty else { return }
        let held = await ablage.load([MetricRecord].self, name: Self.documentName).value ?? []
        let kept = MetricRecord.kept(held, adding: new, now: now)
        do {
            try await ablage.save(kept, name: Self.documentName, isEmpty: kept.isEmpty)
        } catch {
            Logger.library.error("METRICS save failed: \(String(describing: error), privacy: .public)")
        }
        for record in new {
            Logger.library.notice("METRICS \(record.logLine, privacy: .public)")
        }
    }

    /// What the page shows: the records, or that the kept file could not be
    /// read (it lies aside as `.corrupt`). An unreadable file is not "none
    /// yet", which is what the page said before.
    enum Reading: Sendable, Equatable {
        case records([MetricRecord])
        case unreadable
    }

    func records() async -> Reading {
        switch await ablage.load([MetricRecord].self, name: Self.documentName) {
        case .fresh: return .records([])
        case .loaded(let records): return .records(records)
        case .corrupt: return .unreadable
        }
    }
}
