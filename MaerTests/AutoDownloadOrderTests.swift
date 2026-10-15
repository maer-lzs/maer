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

    /// The cases live in `Fixtures/Shared/abos/auto-download-order.json`, read
    /// by Swift and Kotlin alike: the measured case (726 episodes, at 100),
    /// one episode out of the row is not the place, the anchor's gap, and
    /// the edges (no mark, a skipped episode, a download, all heard).
    nonisolated static let order = SharedCases.cases("auto-download-order")

    /// The episodes e1 to eN, pubDate = number, as the file names them.
    private static func episodes(_ value: JSONValue?) -> [PodcastAutoDownloadRules.Candidate] {
        (1...max(1, value?["count"]?.int ?? 1)).map { .init(guid: "e\($0)", pubDate: Double($0)) }
    }

    @Test("gemeinsame Faelle: auto-download-order traegt dreizehn Faelle")
    func orderCasesLoaded() {
        #expect(Self.order.count == 13)
    }

    @Test("gemeinsame Faelle: Der Reihe nach antwortet je Fall wie die Datei sagt", arguments: order)
    func nextInOrder(_ c: SharedCase) throws {
        let input = try c.value("input")
        switch c.ask {
        case "nextInOrder":
            let played = Set(input["played"]?.strings ?? [])
            let started = Set(input["started"]?.strings ?? [])
            let local = Set(input["local"]?.strings ?? [])
            let picked = PodcastAutoDownloadRules.nextInOrder(
                Self.episodes(input["episodes"]), isPlayed: { played.contains($0) },
                isStarted: { started.contains($0) }, isDownloaded: { local.contains($0) },
                limit: try #require(input["limit"]?.int))
            #expect(picked == c["expect"]?.strings, "\(c.slug)")
            for forbidden in c["mustNotContain"]?.strings ?? [] {
                #expect(!picked.contains(forbidden), "\(c.slug): \(forbidden)")
            }
        case "anchorIndex":
            let marked = try #require(input["marked"]?.array).compactMap(\.bool)
            #expect(PodcastAutoDownloadRules.anchorIndex(marked: marked) == c["expect"]?.int, "\(c.slug)")
        default:
            Issue.record("\(c.slug): unknown ask \(c.ask)")
        }
    }

    @Test("G14-1: angefangen heisst eine halbe Minute, wie bei Weiterhoeren, an der Stelle, die den Lauf baut", .needsTheSources)
    func begunMeansHalfAMinute() throws {
        #expect(PodcastAutoDownloadRules.startedAtLeast == 30)
        #expect(PodcastAutoDownloadRules.runGap == 3)
        let helpers = try Self.source("Sources/Views/Podcasts/PodcastHelpers.swift")
        #expect(helpers.contains("case .inProgress(_, let remaining) = progress.state(guid: guid, duration: episode.duration) else { return false } return episode.duration - remaining >= PodcastAutoDownloadRules.startedAtLeast"))
    }

    @Test("Blatt: jedes Feld schreibt nur eine Aenderung, das Oeffnen schreibt nichts", .needsTheSources)
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

    @Test("Messung: der Lauf schreibt je Sendung Richtung, Stichtag und Wahl, und der Bericht nennt den Zustand", .needsTheSources)
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
