// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Siri and Spotlight in 3.9, as decided: a whole show plays its begun
/// episode, else its newest unheard one; a list may start shuffled; a tap
/// on a book in Spotlight opens its page and plays nothing.
struct SiriThreeNineTests {
    static func show(_ guids: [String]) -> PodcastShow {
        PodcastShow(id: "show", title: "Show", author: nil, artworkURL: nil, description: nil,
                    feedURL: "https://feed.example/show",
                    episodes: guids.enumerated().map { index, guid in
                        PodcastEpisode(guid: guid, title: guid, audioURL: "https://media.example/\(index).mp3",
                                       pubDate: Double(index + 1) * 1000, duration: 3000)
                    })
    }

    @Test("a whole show: its begun episode, else its newest unheard one, nothing when all is heard")
    func wholeShow() {
        let show = Self.show(["rss:f:1", "rss:f:2", "rss:f:3", "abspod:x"])
        func start(_ states: [String: EpisodePlayState]) -> String? {
            EpisodeOffer.showStart(show) { states[$0.guid] ?? .unplayed }
        }
        #expect(start([:]) == "rss:f:3", "nothing begun: the newest offered")
        #expect(start(["rss:f:1": .inProgress(fraction: 0.4, remaining: 900)]) == "rss:f:1", "the begun one first")
        #expect(start(["rss:f:3": .played]) == "rss:f:2", "the newest unheard")
        #expect(start(["rss:f:1": .played, "rss:f:2": .played, "rss:f:3": .played]) == nil)
    }

    @Test("a list asked shuffled starts shuffled", .enabled(if: { if #available(iOS 27, *) { true } else { false } }()))
    @MainActor
    func listShuffled() async throws {
        guard #available(iOS 27, *) else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("siri-shuffle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MaerPlaylists(database: MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path))
        let list = store.create(name: "Abendrunde")
        let kept = PlaylistStart.start
        defer { PlaylistStart.start = kept }
        var asked: [Bool] = []
        PlaylistStart.start = { _, shuffled in
            asked.append(shuffled)
            return true
        }
        try await PlaylistStart.run(listId: list.id, shuffled: true, in: store) { true }
        try await PlaylistStart.run(listId: list.id, in: store) { true }
        #expect(asked == [true, false])
    }

    @Test("Siri's play asks the show and the shuffle; the list's start shuffles; Spotlight opens the page", .needsTheSources)
    func surfaces() throws {
        let shortcuts = try FetchAnswerTests.squeezedSource("Sources/AppShortcuts.swift")
        #expect(shortcuts.contains("case show(PodcastShowEntity)"), "a show is no kind Siri may play")
        #expect(shortcuts.contains("case .show(let showId):"), "the play does not start a show")
        #expect(shortcuts.contains("shuffled: playbackAttributes.contains(.shuffle)"), "the shuffle wish is not followed")
        #expect(shortcuts.contains("struct OpenAudiobookIntent: OpenIntent"), "Spotlight has no way to the page")
        let routine = try FetchAnswerTests.squeezedSource("Sources/Providers/RoutinePlayback.swift")
        #expect(routine.contains("shuffled ? await coordinator.shufflePlay("), "the list's start cannot shuffle")
        let root = try FetchAnswerTests.squeezedSource("Sources/Views/LibraryView.swift")
        #expect(root.contains("BookPageRequest.take()"), "the root does not open the asked page")
    }

    @Test("the page request is taken once")
    @MainActor
    func pageRequestOnce() {
        BookPageRequest.pending = "li_book"
        #expect(BookPageRequest.take() == "li_book")
        #expect(BookPageRequest.take() == nil)
    }
}
#endif
