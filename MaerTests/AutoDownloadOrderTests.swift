// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// GT-14: "in order" fetches from where the listener is, the settings sheet
/// writes only what changed, and a run says which direction it read.
struct AutoDownloadOrderTests {
    private static func squeezed(_ raw: String) -> String {
        SyncContractFenceTests.stripped(raw)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return squeezed(try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8))
    }

    private static func show(_ count: Int) -> [PodcastAutoDownloadRules.Candidate] {
        (1...count).map { .init(guid: "e\($0)", pubDate: Double($0)) }
    }

    private static func pick(_ episodes: [PodcastAutoDownloadRules.Candidate], played: Set<String> = [],
                             started: Set<String> = [], local: Set<String> = []) -> [String] {
        PodcastAutoDownloadRules.nextInOrder(episodes, isPlayed: { played.contains($0) },
                                             isStarted: { started.contains($0) },
                                             isDownloaded: { local.contains($0) }, limit: 3)
    }

    @Test("Der Reihe nach: der Fall am Wortlaut, 726 Folgen, bei Nr. 100: die naechsten danach, nie die neuesten")
    func theMeasuredCase() {
        let episodes = Self.show(726)
        // Episode 100 finished in the app, 1 to 99 heard before it never
        // carried a mark here.
        #expect(Self.pick(episodes, played: ["e100"]) == ["e101", "e102", "e103"])
        // Episode 100 begun: it comes first.
        #expect(Self.pick(episodes, started: ["e100"]) == ["e100", "e101", "e102"])
        #expect(!Self.pick(episodes, played: ["e100"]).contains("e726"), "never the newest")
    }

    @Test("Der Reihe nach: ohne Marke vom Anfang, Uebersprungenes bleibt liegen, Geladenes zaehlt nicht")
    func theEdges() {
        let episodes = Self.show(10)
        #expect(Self.pick(episodes) == ["e1", "e2", "e3"], "no mark: from the start, as before")
        #expect(Self.pick(episodes, played: ["e8"]) == ["e9", "e10"],
                "e7 skipped on the way is the listener's choice, not fetched back")
        #expect(Self.pick(episodes, played: ["e3"], local: ["e4"]) == ["e5", "e6", "e7"])
        #expect(Self.pick(episodes, played: Set((1...10).map { "e\($0)" })).isEmpty, "all heard: nothing")
    }

    @Test("Blatt: jedes Feld schreibt nur eine Aenderung, das Oeffnen schreibt nichts")
    func theSheetWritesOnlyChanges() throws {
        let sheet = try Self.source("Sources/Views/Podcasts/PodcastShowSettingsSheet.swift")
        for (field, guardLine) in [
            ("rate", "guard new != AppStorageKeys.float(AppStorageKeys.podcastShowRate(showId)) else { return }"),
            ("autoDownloadMode", "guard mode != PodcastAutoDownload.mode(showId) else { return }"),
            ("inboxMode", "guard m != AppStorageKeys.podcastInboxModeValue(showId) else { return }"),
            ("notify", "guard on != AppStorageKeys.podcastNotifyEnabled(showId) else { return }"),
            ("episodeLimit", "guard n != AppStorageKeys.podcastEpisodeLimitValue(showId) else { return }"),
        ] {
            let change = try #require(sheet.range(of: ".onChange(of: \(field)) {"), "\(field)")
            let check = try #require(sheet.range(of: guardLine), "\(field) has no guard")
            #expect(change.upperBound <= check.lowerBound, "\(field): the guard sits in its own handler")
        }
    }

    @Test("Messung: der Lauf schreibt je Sendung Richtung, Stichtag und Wahl, und der Bericht nennt den Zustand")
    @MainActor
    func theRunSaysWhatItRead() throws {
        let helpers = try Self.source("Sources/Views/Podcasts/PodcastHelpers.swift")
        #expect(helpers.contains("Logger.library.notice(\"AUTODOWNLOAD show=\\(show.id, privacy: .public) mode=\\(mode(show.id).rawValue"))
        let sheet = try Self.source("Sources/Views/Podcasts/PodcastShowSettingsSheet.swift")
        #expect(sheet.contains("return report + \"\\n\" + PodcastAutoDownload.stateLine(showId, format: format)"))

        let showId = "feed:witness-\(UUID().uuidString)"
        defer {
            AppStorageKeys.remove("podcastAutoDownloadMode.\(showId)")
            AppStorageKeys.remove(PodcastAutoDownload.flagKey(showId))
        }
        // The old switch alone reads as "newest", and the line says so.
        AppStorageKeys.set(true, for: PodcastAutoDownload.flagKey(showId))
        #expect(PodcastAutoDownload.stateLine(showId, format: { _ in "t" }).contains("newest (from the old switch)"))
        PodcastAutoDownload.setMode(showId, .inOrder)
        #expect(PodcastAutoDownload.stateLine(showId, format: { _ in "t" }).contains("inOrder (chosen)"))
    }
}
#endif
