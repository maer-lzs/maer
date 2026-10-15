// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The measuring points stand where the plan put them, go through the one
/// file, and carry no identifier: a site calls a named function whose
/// parameters are enums, numbers and flags, and nothing else touches a
/// signposter.
struct PerfSignpostFenceTests {
    /// File name to the calls it must carry.
    static let sites: [String: [String]] = [
        "PlayerViewModel.swift": ["PerfSignpost.tick(playing:"],
        "PlayerViewModel+NowPlaying.swift": ["PerfSignpost.nowPlaying(newArtwork:"],
        "ListeningStats.swift": ["PerfSignpost.statsMerge()"],
        "PlayerViewModel+Sync.swift": ["PerfSignpost.syncLoop(playing:", "PerfSignpost.syncRound(.serverProgress, .server)"],
        "PlaybackClaimSync.swift": ["PerfSignpost.syncRound(.claim, signpostCarrier)",
                                    "PerfSignpost.syncRound(.claimPoll, signpostCarrier)"],
        "StandCarrier.swift": ["PerfSignpost.syncRound(.stand, .keyValue)"],
        "CloudKitStandCarrier.swift": ["PerfSignpost.syncRound(.stand, .cloudKit)"],
        "MaerSyncCarriers.swift": ["PerfSignpost.syncRound(.service, .maerSync)", "PerfSignpost.syncRound(.stand, .maerSync)",
                                   "PerfSignpost.syncRound(.stats, .maerSync)", "PerfSignpost.syncRound(.playlists, .maerSync)"],
        "StatsCarrier.swift": ["PerfSignpost.syncRound(.stats, .keyValue)"],
        "CloudKitStatsCarrier.swift": ["PerfSignpost.syncRound(.stats, .cloudKit)"],
        "PlaylistCarrier.swift": ["PerfSignpost.syncRound(.playlists, .keyValue)"],
        "CloudKitPlaylistCarrier.swift": ["PerfSignpost.syncRound(.playlists, .cloudKit)"],
        "CloudKitChoiceCarrier.swift": ["PerfSignpost.syncRound(.choices, .cloudKit)"],
        "UserChoiceCloudSync.swift": ["PerfSignpost.syncRound(.userChoices, .local)"],
        "FeedAuthSync.swift": ["PerfSignpost.syncRound(.feedAuth, .maerSync)"],
        "GPodderSync.swift": ["PerfSignpost.syncRound(.gpodder, .server)"],
        "PodcastCloudSync.swift": ["PerfSignpost.standMerge(entries: local.count)"],
        "PodcastSubscriptions.swift": ["PerfSignpost.feedParse()"],
        "ImageCache.swift": ["PerfSignpost.thumbnailHit()", "PerfSignpost.coverDecode()", "PerfSignpost.coverOriginalCached("],
        "LibraryViewModel.swift": ["PerfSignpost.downloadedRecompute()"],
        "MaerSyncStandingReader.swift": ["PerfSignpost.standingRead()"],
        "MaerSyncClient.swift": ["PerfSignpost.accessRead()"],
        "BottomBarState.swift": ["PerfSignpost.barCollapsedFlip("],
    ]

    /// The functions that open an interval; each call needs its `end()`.
    static let intervalOpeners = ["tick(", "statsMerge(", "syncRound(", "standMerge(", "feedParse(",
                                  "coverDecode(", "downloadedRecompute(", "accessRead("]

    /// Code lines only: a comment about a signpost is no signpost.
    static func code(_ text: String) -> [String] {
        text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    /// Direct signposter use in one file's code.
    static func directUse(_ text: String) -> Int {
        code(text).filter { line in
            ["OSSignposter(", "os_signpost(", "mxSignpost(", "makeLogHandle(", ".beginInterval(", ".endInterval(",
             ".emitEvent("].contains { line.contains($0) }
        }.count
    }

    /// Interval calls and closings in one file's code.
    static func intervalBalance(_ text: String) -> (opened: Int, closed: Int) {
        let lines = code(text)
        let opened = lines.filter { line in intervalOpeners.contains { line.contains("PerfSignpost." + $0) } }.count
        let closed = lines.filter { $0.contains("signpost.end()") }.count
        return (opened, closed)
    }

    /// The parameter types of `PerfSignpost`'s functions.
    static func parameterTypes(_ text: String) -> [String] {
        let pattern = #/static func \w+\(([^)]*)\)/#
        return text.matches(of: pattern).flatMap { match in
            String(match.1).split(separator: ",").compactMap { parameter -> String? in
                let parts = parameter.split(separator: ":")
                return parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
            }
        }
    }

    /// The names a call in the file writes: plain intervals and events, and
    /// the snapshot intervals.
    static func writtenNames(_ text: String) -> [String] {
        code(text).joined(separator: "\n")
            .matches(of: #/(?:beginInterval|emitEvent)\("([^"]+)"|snapshotInterval\(\.?\w+, "([^"]+)"\)/#)
            .compactMap { match in (match.1 ?? match.2).map(String.init) }
    }

    /// The names of the snapshot intervals, one per call.
    static func snapshotCalls(_ text: String) -> [String] {
        code(text).joined(separator: "\n").matches(of: #/snapshotInterval\(\.?\w+, "([^"]+)"\)/#).map { String($0.1) }
    }

    @Test("die Zaehler sehen, was sie sehen sollen")
    func theCountersSeeTheForms() {
        #expect(Self.directUse("let s = OSSignposter(subsystem: a, category: b)\n// os_signpost(.event)") == 1)
        #expect(Self.directUse("PerfSignpost.cover.emitEvent(\"x\")") == 1)
        #expect(Self.directUse("mxSignpost(.begin, log: l, name: \"x\")\nlet l = MXMetricManager.makeLogHandle(category: \"c\")") == 2)
        #expect(Self.writtenNames("a.beginInterval(\"tick\", id: i)\nb.emitEvent(\"hit\")\nsnapshotInterval(.sync, \"syncRound\")")
                == ["tick", "hit", "syncRound"])
        #expect(Self.snapshotCalls("return snapshotInterval(.feeds, \"feedParse\")\nfunc snapshotInterval(_ category: Category") == ["feedParse"])
        let balanced = Self.intervalBalance("let signpost = PerfSignpost.tick(playing: true)\ndefer { signpost.end() }")
        #expect(balanced.opened == 1)
        #expect(balanced.closed == 1)
        #expect(Self.parameterTypes("static func a(x: Int, _ f: Family) -> I\nstatic func b()") == ["Int", "Family"])
    }

    @Test("kein Signposter ausserhalb von PerfSignpost, jede Messstelle steht da, jedes Intervall schliesst", .needsTheSources)
    func theMeasuringPointsStandAndGoThroughOneFile() throws {
        let files = ProjectFileIntegrityTests.sourceFiles()
        try #require(files.count > 100, "the sources were not read")
        var direct: [String] = []
        var unbalanced: [String] = []
        var missing: [String] = []
        var seen = Set<String>()
        for file in files {
            let name = file.lastPathComponent
            let text = try String(contentsOf: file, encoding: .utf8)
            if name == "PerfSignpost.swift" { continue }
            if Self.directUse(text) > 0 { direct.append(name) }
            let balance = Self.intervalBalance(text)
            if balance.opened != balance.closed { unbalanced.append("\(name) \(balance.opened)/\(balance.closed)") }
            if let calls = Self.sites[name] {
                seen.insert(name)
                missing += calls.filter { !text.contains($0) }.map { "\(name): \($0)" }
            }
        }
        #expect(direct.isEmpty, "\(direct)")
        #expect(unbalanced.isEmpty, "\(unbalanced)")
        #expect(missing.isEmpty, "\(missing)")
        #expect(seen == Set(Self.sites.keys), "\(Set(Self.sites.keys).subtracting(seen))")
    }

    @Test("eine Messstelle nimmt nur Wahrheitswerte, Zahlen, Familie und Traeger", .needsTheSources)
    func theParametersCarryNoIdentifier() throws {
        let file = try #require(ProjectFileIntegrityTests.sourceFiles().first { $0.lastPathComponent == "PerfSignpost.swift" })
        let types = Self.parameterTypes(try String(contentsOf: file, encoding: .utf8))
        try #require(!types.isEmpty, "no parameter read")
        let allowed: Set<String> = ["Bool", "Int", "Family", "Carrier"]
        #expect(Set(types).isSubset(of: allowed), "\(Set(types).subtracting(allowed))")
    }

    /// MetricKit keeps only signposts on its own logs. Behind the open gate
    /// every signposter stands on one, the app's own logs are the other
    /// side, and the expensive snapshot stands only at the named rare
    /// intervals.
    @Test("die Messstellen schreiben auf Logs von MetricKit, der Schnappschuss nur an den seltenen Intervallen", .needsTheSources)
    func theSignpostsReachMetricKit() throws {
        let file = try #require(ProjectFileIntegrityTests.sourceFiles().first { $0.lastPathComponent == "PerfSignpost.swift" })
        let text = try String(contentsOf: file, encoding: .utf8)
        let lines = Self.code(text)
        func count(_ form: String) -> Int { lines.filter { $0.contains(form) }.count }
        #expect(count("OSSignposter(subsystem:") == 1 && count("OSSignposter(logHandle:") == 1 && count("OSSignposter(") == 2,
                "one signposter per side: the app's own logs and MetricKit's")
        #expect(count("MXMetricManager.makeLogHandle(category:") == 1, "MetricKit's logs are made in one place")
        let calls = Self.snapshotCalls(text)
        #expect(calls.sorted() == PerfSignpost.snapshotNames.sorted(), "the snapshot only at the named list: \(calls)")
        #expect(count("mxSignpost(") == 2, "the snapshot is written in one place, its begin and its end")
        #expect(!PerfSignpost.snapshotNames.contains { ["tick", "statsMerge", "decode"].contains($0) },
                "a frequent interval carries the snapshot")
    }

    /// The gate holds for the measuring points too: closed or undecided, no
    /// signpost writes to a log of MetricKit and no snapshot is taken.
    /// MetricKit's logs are reached only where the gate is asked, and the
    /// gate opens them once, behind the receiver's gate.
    @Test("geschlossen oder unentschieden schreibt keine Messstelle auf einen Log von MetricKit", .needsTheSources)
    func theGateHoldsForTheMeasuringPoints() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let signposts = Self.code(try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/PerfSignpost.swift"),
                                             encoding: .utf8))
        let reaching = signposts.filter { $0.contains("KeptLogs.") }
        try #require(reaching.count == 2, "MetricKit's logs are reached in the signposter and the snapshot: \(reaching)")
        #expect(reaching.allSatisfy { $0.contains("PerfSignpost.isMeasuring") }, "a line reaches MetricKit's logs without the gate: \(reaching)")
        #expect(signposts.contains { $0.contains("OSAllocatedUnfairLock(initialState: false)") }, "the measuring points start closed")
        let receiver = try code("Sources/Networking/MetricReceiver.swift")
        let gate = try #require(receiver.range(of: "guard on else { return }"))
        let open = try #require(receiver.range(of: "PerfSignpost.measure()"))
        #expect(gate.upperBound <= open.lowerBound, "the measuring points open before the gate")
        var opens = 0
        for file in ProjectFileIntegrityTests.sourceFiles() {
            opens += SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
                .components(separatedBy: "PerfSignpost.measure()").count - 1
        }
        #expect(opens == 1, "one place opens the measuring points")
    }

    /// The list a day's record checks against is every name the file
    /// writes, each once.
    @Test("die Liste der Namen ist jeder geschriebene Name, jeder einmal", .needsTheSources)
    func theNamesListIsEveryWrittenName() throws {
        let file = try #require(ProjectFileIntegrityTests.sourceFiles().first { $0.lastPathComponent == "PerfSignpost.swift" })
        let written = Self.writtenNames(try String(contentsOf: file, encoding: .utf8))
        try #require(!written.isEmpty, "no name read")
        #expect(Set(written) == Set(PerfSignpost.names), "\(Set(written).symmetricDifference(PerfSignpost.names))")
        #expect(Set(PerfSignpost.names).count == PerfSignpost.names.count, "a name stands twice in the list")
    }

    /// The merge's snapshot carries no number, so an event at its start
    /// names how many positions the device brought, the way a sync round
    /// names its family and carrier.
    @Test("die Zusammenfuehrung nennt ihre Zahl in einem Ereignis davor", .needsTheSources)
    func theMergeNamesItsCount() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let signposts = try code("Sources/PerfSignpost.swift")
        let event = try #require(signposts.range(of: #"emitEvent("standMergeOf", "entries=\(entries)")"#),
                                 "the merge names no count")
        let interval = try #require(signposts.range(of: #"snapshotInterval(.sync, "standMerge")"#))
        #expect(event.upperBound <= interval.lowerBound, "the count comes after the interval opened")
        #expect(try code("Sources/Networking/PodcastCloudSync.swift").contains("PerfSignpost.standMerge(entries: local.count)"),
                "the merge is called without the positions it merges")
    }

    /// Apple calls a plain signpost nearly free without a recording tool.
    /// The inventory says that once, and says what it does not hold for:
    /// the snapshot and the question to the switch.
    @Test("das Inventar sagt, wofuer nahezu kostenlos gilt", .needsTheSources)
    func theInventorySaysWhatIsNearlyFree() throws {
        let inventory = try String(contentsOf: SourceTree.root.appendingPathComponent("docs/components.md"), encoding: .utf8)
        let sentences = inventory.components(separatedBy: ". ").filter { $0.contains("nahezu kostenlos") }
        try #require(sentences.count == 1, "the claim stands \(sentences.count) times")
        let sentence = sentences[0]
        #expect(sentence.contains("gewoehnlicher Signpost") && sentence.contains("`mxSignpost`") && sentence.contains("Schalter"),
                "the claim does not say what it holds for: \(sentence.suffix(300))")
    }

    /// The fences of the measuring instrument read the source tree; where
    /// it does not lie beside the run, each one is skipped, never passed.
    @Test("jeder Zaun des Messinstruments, der den Quellbaum liest, steht unter needsTheSources", .needsTheTests)
    func everyMeasuringFenceNeedsTheSources() throws {
        var unmarked: [String] = []
        for name in ["PerfSignpostFenceTests.swift", "MetricGateTests.swift"] {
            let text = try String(contentsOf: SourceTree.root.appendingPathComponent("MaerTests/" + name), encoding: .utf8)
            let cases = text.components(separatedBy: "\n    @Test(").dropFirst()
            try #require(!cases.isEmpty, "no case read in \(name)")
            for item in cases where item.contains("sourceFiles()") || item.contains("SourceTree.root") {
                let head = item.components(separatedBy: "func ").first ?? ""
                if !head.contains(".needsTheSources") && !head.contains(".needsTheTests") {
                    unmarked.append("\(name): " + (head.components(separatedBy: "\"").dropFirst().first ?? head))
                }
            }
        }
        #expect(unmarked.isEmpty, "\(unmarked)")
    }
}
#endif
