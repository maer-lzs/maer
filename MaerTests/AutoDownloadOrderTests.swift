// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// "In order" fetches from where the listener is, the settings sheet
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

    @Test("G14-1: eine Folge ausserhalb der Reihe ist nicht die Stelle, angespielt oder ganz gehoert")
    func oneEpisodeOutOfTheRowIsNotThePlace() {
        let episodes = Self.show(727)
        // At 100, the new 727 tried (begun past the half minute) or heard as a special.
        #expect(Self.pick(episodes, played: ["e100"], started: ["e727"]) == ["e101", "e102", "e103"])
        #expect(Self.pick(episodes, played: ["e100", "e727"]) == ["e101", "e102", "e103"])
        // The run 100, 101 and a special far ahead: after the run.
        #expect(Self.pick(episodes, played: ["e100", "e101", "e727"]) == ["e102", "e103", "e104"])
        // Jumped ahead and kept going: the later run is the place.
        #expect(Self.pick(episodes, played: ["e1", "e2", "e3", "e500", "e501"]) == ["e502", "e503", "e504"])
        // A skipped episode or two stays one run; a gap of four does not.
        #expect(PodcastAutoDownloadRules.anchorIndex(marked: [true, false, false, false, true]) == 4)
        #expect(PodcastAutoDownloadRules.anchorIndex(marked: [true, false, false, false, false, true]) == 0)
        #expect(PodcastAutoDownloadRules.anchorIndex(marked: [false, false]) == nil)
    }

    @Test("G14-1: angefangen heisst eine halbe Minute, wie bei Weiterhoeren, an der Stelle, die den Lauf baut")
    func begunMeansHalfAMinute() throws {
        #expect(PodcastAutoDownloadRules.startedAtLeast == 30)
        #expect(PodcastAutoDownloadRules.runGap == 3)
        let helpers = try Self.source("Sources/Views/Podcasts/PodcastHelpers.swift")
        #expect(helpers.contains("case .inProgress(_, let remaining) = progress.state(guid: guid, duration: episode.duration) else { return false } return episode.duration - remaining >= PodcastAutoDownloadRules.startedAtLeast"))
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
            ("notify", "guard on != AppStorageKeys.podcastNotifyEnabled(showId) else { return }"),
        ] {
            let change = try #require(sheet.range(of: ".onChange(of: \(field)) {"), "\(field)")
            let check = try #require(sheet.range(of: guardLine), "\(field) has no guard")
            #expect(change.upperBound <= check.lowerBound, "\(field): the guard sits in its own handler")
        }
        // The three values a show can take from all shows write
        // through a binding the hand reaches, never through `onChange`, and
        // only a value the show does not already act on.
        #expect(!sheet.contains(".onChange(of: own"), "filling the sheet would write again")
        let binding = try #require(functionBody(of: "private func ownBinding(", in: sheet))
        let settle = try #require(binding.range(of: "guard raw != field.stored(showId) else { return }"))
        let write = try #require(binding.range(of: "field.setOwn(raw, showId: showId)"))
        #expect(settle.upperBound <= write.lowerBound, "the guard sits before the write")
        let fields = try Self.source("Sources/ViewModels/PodcastGeneralSettings.swift")
        let setOwn = try #require(functionBody(of: "func setOwn(", in: fields))
        #expect(setOwn.contains("guard raw != PodcastGeneralRule.effective(stored: stored(showId), general: general) else { return }"))
    }

    @Test("Messung: der Lauf schreibt je Sendung Richtung, Stichtag und Wahl, und der Bericht nennt den Zustand")
    @MainActor
    func theRunSaysWhatItRead() throws {
        let helpers = try Self.source("Sources/Views/Podcasts/PodcastHelpers.swift")
        #expect(helpers.contains("Logger.library.notice(\"AUTODOWNLOAD show=\\(show.id, privacy: .public) direction=\\(direction.rawValue, privacy: .public) keep=\\(keep)"))
        let sheet = try Self.source("Sources/Views/Podcasts/PodcastShowSettingsSheet.swift")
        #expect(sheet.contains("return report + \"\\n\" + PodcastAutoDownload.stateLine(showId, format: format)"))

        let showId = "feed:witness-\(UUID().uuidString)"
        defer {
            AppStorageKeys.remove("podcastAutoDownloadMode.\(showId)")
            AppStorageKeys.remove(PodcastAutoDownload.flagKey(showId))
            AppStorageKeys.remove(PodcastAutoDownload.directionKey(showId))
        }
        // The value of an older build reads as on plus its direction, and
        // the line says where the direction came from.
        AppStorageKeys.set("inOrder", for: "podcastAutoDownloadMode.\(showId)")
        AppStorageKeys.set(true, for: PodcastAutoDownload.flagKey(showId))
        #expect(PodcastAutoDownload.stateLine(showId, format: { _ in "t" })
            .contains("on (chosen), direction inOrder (from the older setting)"))
        AppStorageKeys.set("newest", for: PodcastAutoDownload.directionKey(showId))
        #expect(PodcastAutoDownload.stateLine(showId, format: { _ in "t" }).contains("direction newest (chosen)"))
    }
}
#endif
