// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The explicit mark of podcasts: one rule, one letter, on episode rows, the
/// episode page and the show page.
struct PodcastExplicitTests {
    @Test("an episode carries the E by its own flag, without one by the flag of the show")
    func theEpisodeTagWinsElseTheShow() {
        #expect(PodcastExplicit.marks(episode: true, show: false))
        #expect(!PodcastExplicit.marks(episode: false, show: true), "a clean episode of an explicit show")
        #expect(PodcastExplicit.marks(episode: nil, show: true))
        #expect(!PodcastExplicit.marks(episode: nil, show: nil))
        #expect(PodcastExplicit.marks(show: true) && !PodcastExplicit.marks(show: nil))
    }

    @Test("row, episode page and show ask the one rule, no place writes the E itself", .needsTheSources)
    func everySurfaceAsksTheRule() throws {
        func source(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(
                contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let row = try source("Sources/Views/Podcasts/PodcastComponents.swift")
        #expect(row.contains("PodcastExplicit.marks(episode: $0.episode.explicit, show: $0.show.explicit)"))
        #expect(try source("Sources/Views/Podcasts/PodcastShowView.swift").contains("ExplicitMark()"))
        #expect(try source("Sources/Views/Podcasts/PodcastEpisodeDetailView.swift").contains("PodcastExplicit.marks("))
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]) {
            let code = SyncContractFenceTests.stripped(text)
            #expect(!code.contains("Text(\"E\")") && !code.contains("? \"E\" :"), "\(name) writes the mark itself")
        }
    }

    /// The row's facts come from the store its list observes, any store:
    /// a kept episode without an enclosure is text only, the show's tag
    /// marks a clean episode of it, and an episode no show holds plays.
    @Test("the facts of an episode row come from the store the list observes, from any of them")
    @MainActor
    func theRowsFactsComeFromTheObservedStore() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("episode-facts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "episode-facts-\(UUID().uuidString)"
        let own = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let subs = PodcastSubscriptions(fileURL: folder.appendingPathComponent("podcast_subscriptions.json"),
                                        database: MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path),
                                        defaults: own, isTheApp: false)
        await subs.ensureLoaded()
        var spoken = PodcastEpisode(guid: "rss:facts:1", title: "Gesprochen", audioURL: "https://feeds.example/1.mp3",
                                    pubDate: 1, duration: 600)
        spoken.explicit = false
        let textOnly = PodcastEpisode(guid: "rss:facts:2", title: "Nur Text", audioURL: "", pubDate: 2, duration: 0)
        var show = PodcastShow(id: "feed:facts", title: "Fakten", author: nil, artworkURL: nil, description: nil,
                               feedURL: "https://feeds.example/facts.xml", episodes: [spoken, textOnly])
        show.explicit = true
        subs._seedForUITest([show])
        #expect(PodcastEpisodeFacts.of("rss:facts:1", in: subs) == PodcastEpisodeFacts(isPlayable: true, marksExplicit: false),
                "the episode's own tag wins over the show's")
        #expect(PodcastEpisodeFacts.of("rss:facts:2", in: subs) == PodcastEpisodeFacts(isPlayable: false, marksExplicit: true),
                "text only, marked by the show")
        #expect(PodcastEpisodeFacts.of("rss:facts:9", in: subs) == PodcastEpisodeFacts(), "an episode no show holds plays")
        #expect(PodcastEpisodeFacts.of("abspod:x:1", in: subs) == PodcastEpisodeFacts())
        #expect(PodcastSubscriptions.isPlayableEpisode(itemId: "abspod:x:1", episode: textOnly),
                "only a kept feed episode can be text only")
        #expect(!PodcastSubscriptions.isPlayableEpisode(itemId: "rss:facts:2", episode: textOnly))
        #expect(PodcastSubscriptions.isPlayableEpisode(itemId: "rss:facts:2", episode: nil))
    }

    /// The row and the page reach no subscription store of their own; each
    /// caller of the row hands the facts from the store it observes.
    @Test("episode row and episode page grab no subscription store, the callers pass it in", .needsTheSources)
    func theRowAndThePageReachNoStore() throws {
        func source(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(
                contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let row = try #require(functionBody(of: "struct PodcastEpisodeRow: View {",
                                            in: try source("Sources/Views/Podcasts/PodcastComponents.swift")))
        #expect(!row.contains("PodcastSubscriptions"), "the row reaches the store")
        let page = try source("Sources/Views/Podcasts/PodcastEpisodeDetailView.swift")
        #expect(!page.contains("PodcastSubscriptions.shared"), "the page reaches the store")
        #expect(page.contains("PodcastSubscriptions.isPlayableEpisode(itemId: item.id, episode: podcastEpisode)"))
        var callers = 0
        for path in ["Sources/Views/PodcastsView.swift", "Sources/Views/Podcasts/PodcastShowView.swift"] {
            let text = try source(path)
            let hits = text.components(separatedBy: "facts: .of(item.id, in: subs)").count - 1
            callers += hits
            #expect(hits == 0 || text.contains("@ObservedObject private var subs = PodcastSubscriptions.shared"),
                    "\(path) hands facts from a store it does not observe")
        }
        let rows = ProjectFileIntegrityTests.sourceTexts(in: ["Sources"])
            .map { $0.text.components(separatedBy: "PodcastEpisodeRow(item:").count - 1 }.reduce(0, +)
        #expect(callers == 3 && rows == 3, "every row is handed its facts: \(callers) of \(rows)")
    }
}
#endif
