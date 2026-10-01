// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Two token twins of one show in the rows. The start reads the heads first,
/// where both carry no episodes, and the full rows after. Only the full stage
/// has the ground to fold ("the fuller survives"); after it the rows hold the
/// survivor alone, so the next start finds nothing left to fold.
@MainActor
struct TokenTwinTwoStageTests {
    private static func show(_ url: String, episodes: Int, tag: String) -> PodcastShow {
        let key = PodcastSubscriptions.feedKey(url)
        return PodcastShow(id: "feed:\(key)", title: "Zwilling", author: nil, artworkURL: nil,
                           description: nil, feedURL: url,
                           episodes: (0..<episodes).map {
                               PodcastEpisode(guid: "rss:\(key):\(tag)-\($0)", title: "Folge \($0)",
                                              audioURL: "https://premium.example/\(tag)/\($0).mp3",
                                              pubDate: Double($0 + 1) * 1000, duration: 600)
                           })
    }

    @Test("Zwei Token-Zwillinge: nach dem ersten Start steht nur der vollere in den Zeilen, der zweite Start faltet nichts mehr")
    func theRowsHoldTheSurvivorAloneAfterOneStart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("twin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "twin-two-stage-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let run = UUID().uuidString.prefix(8)
        let oldURL = "https://premium.example/feed.xml?token=alt\(run)"
        let newURL = "https://premium.example/feed.xml?token=neu\(run)"
        // The precondition: one masked identity, two keys, so they ARE twins.
        #expect(PodcastSubscriptions.collapseKey(oldURL) == PodcastSubscriptions.collapseKey(newURL))
        #expect(PodcastSubscriptions.feedKey(oldURL) != PodcastSubscriptions.feedKey(newURL))

        let database = MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path)
        // The OLD token first and thinner: on order alone it would win.
        try await PodcastRowStore(connection: try database.connection())
            .replaceAll([Self.show(oldURL, episodes: 2, tag: "alt\(run)"),
                         Self.show(newURL, episodes: 5, tag: "neu\(run)")])

        for start in 1...2 {
            let subs = PodcastSubscriptions(fileURL: folder.appendingPathComponent("podcast_subscriptions.json"),
                                            database: database, defaults: defaults, isTheApp: false)
            await subs.ensureLoaded()
            await subs.awaitPendingWrites()
            #expect(subs.shows.map(\.feedURL) == [newURL], "start \(start): memory holds the fuller twin")
            #expect(subs.shows.first?.episodes.count == 7, "start \(start): \(subs.shows.first?.episodes.count ?? -1)")
            let rows = try await PodcastRowStore(connection: try database.connection()).loadAll()
            #expect(rows.map(\.feedURL) == [newURL],
                    "start \(start): rows \(rows.map { $0.feedURL == oldURL ? "old" : "new" })")
            #expect(rows.first?.episodes.count == 7, "start \(start): \(rows.first?.episodes.count ?? -1)")
        }
    }

    @Test("Die Kopf-Stufe faltet nicht: zwischen den Koepfen und den vollen Zeilen ruft der Start migrated nicht")
    func theHeadStageDoesNotFold() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/Providers/PodcastSubscriptions.swift"),
                              encoding: .utf8)
        let heads = try #require(text.range(of: "let heads = try await rows.loadHeads()"))
        let full = try #require(text.range(of: "rows.loadAllCounted()", range: heads.upperBound..<text.endIndex))
        let between = text[heads.upperBound..<full.lowerBound]
        let code = between.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        #expect(!code.contains { $0.contains("migrated(") }, "the head stage folds again")
    }
}
#endif
