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
        "PodcastCloudSync.swift": ["PerfSignpost.standMerge(entries:"],
        "PodcastSubscriptions.swift": ["PerfSignpost.feedParse(bytes:"],
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
            ["OSSignposter(", "os_signpost(", ".beginInterval(", ".endInterval(", ".emitEvent("].contains { line.contains($0) }
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

    @Test("die Zaehler sehen, was sie sehen sollen")
    func theCountersSeeTheForms() {
        #expect(Self.directUse("let s = OSSignposter(subsystem: a, category: b)\n// os_signpost(.event)") == 1)
        #expect(Self.directUse("PerfSignpost.cover.emitEvent(\"x\")") == 1)
        let balanced = Self.intervalBalance("let signpost = PerfSignpost.tick(playing: true)\ndefer { signpost.end() }")
        #expect(balanced.opened == 1)
        #expect(balanced.closed == 1)
        #expect(Self.parameterTypes("static func a(x: Int, _ f: Family) -> I\nstatic func b()") == ["Int", "Family"])
    }

    @Test("kein Signposter ausserhalb von PerfSignpost, jede Messstelle steht da, jedes Intervall schliesst")
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

    @Test("eine Messstelle nimmt nur Wahrheitswerte, Zahlen, Familie und Traeger")
    func theParametersCarryNoIdentifier() throws {
        let file = try #require(ProjectFileIntegrityTests.sourceFiles().first { $0.lastPathComponent == "PerfSignpost.swift" })
        let types = Self.parameterTypes(try String(contentsOf: file, encoding: .utf8))
        try #require(!types.isEmpty, "no parameter read")
        let allowed: Set<String> = ["Bool", "Int", "Family", "Carrier"]
        #expect(Set(types).isSubset(of: allowed), "\(Set(types).subtracting(allowed))")
    }
}
#endif
