// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// GOAL 3.0, point 1: the search view calls no provider and decides
/// no destination. Both used to lie with it: it asked the music provider and
/// the podcast directory itself, and where a hit leads was decided by
/// `LibraryView`, a caller that has nothing to do with searching. The fence
/// holds the seam; the red probe is in the test itself, because a fence that
/// only reports „0 Verstöße" proves nothing.
struct SearchDoorFenceTests {
    private static func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    /// The provider names a search surface must never know itself.
    private static let providerReaches = [
        "AppSession.shared",
        "ITunesDirectory(",
        "PodcastIndexDirectory(",
        "FreeCatalogProvider.shared",
        "RadioProvider.shared",
        "PodcastSubscriptions.shared",
    ]

    /// The code without comment lines. A fence that searches raw text
    /// would otherwise trip on the rationale that explains why the grip is gone.
    static func code(in text: String) -> String {
        text.components(separatedBy: "\n").filter {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///")
        }.joined(separator: "\n")
    }

    static func hits(_ needles: [String], in text: String) -> [String] {
        let body = code(in: text)
        return needles.filter { body.contains($0) }
    }

    static func reaches(in text: String) -> [String] {
        hits(providerReaches, in: text)
    }

    @Test("The search view asks no provider itself", .needsTheSources)
    func theSearchViewAsksNoProvider() throws {
        #expect(Self.reaches(in: try Self.source("Sources/Views/SearchScreen.swift")).isEmpty)
        // Red probe in both directions: the checker sees the grip…
        #expect(Self.reaches(in: "let x = AppSession.shared.musicProvider") == ["AppSession.shared"])
        // …and a comment above it he does NOT see (the lesson from the
        // fence that tripped on its own rationale).
        #expect(Self.reaches(in: "// uses AppSession.shared.musicProvider").isEmpty)
    }

    @Test("The view no longer decides a destination: no switch over the hit kind", .needsTheSources)
    func theViewDecidesNoTarget() throws {
        // `LibraryView` carries out the destination, but the DECISION is in
        // `SearchRouting`. The telltale is the grip on the KIND.
        let library = try Self.source("Sources/Views/LibraryView.swift")
        #expect(!library.contains("switch result.kind"))
        #expect(library.contains("SearchDoor.target"))
    }

    /// What feeds the deck and how it is built belongs behind the door.
    /// Before, both were in the view: it fetched the shows and the
    /// albums itself, grouped the own library and moved the work
    /// off the main thread itself.
    private static let deckReaches = [
        "PodcastAutoContinue.allShows",
        "LibraryViewModel.authorGroups",
        "LibraryViewModel.genreGroups",
        "Task.detached",
    ]

    @Test("The search view does not build the deck itself", .needsTheSources)
    func theSearchViewDoesNotBuildTheDeck() throws {
        let view = try Self.source("Sources/Views/SearchScreen.swift")
        let found = Self.hits(Self.deckReaches, in: view)
        #expect(found.isEmpty, "die Ansicht baut wieder selbst: \(found)")
        // And it asks the door for it, instead of showing nothing at all.
        #expect(Self.code(in: view).contains("SearchDoor.deck("))
        // Red probe in both directions: the checker would see the old form…
        #expect(Self.hits(Self.deckReaches, in: "let shows = PodcastAutoContinue.allShows()")
                    == ["PodcastAutoContinue.allShows"])
        // …and a comment above the old form he does NOT see.
        #expect(Self.hits(Self.deckReaches, in: "// was PodcastAutoContinue.allShows()").isEmpty)
    }

    @Test("The view does not decide which tiles a scope has", .needsTheSources)
    func theViewDoesNotDecideTheTiles() throws {
        let view = try Self.source("Sources/Views/SearchScreen.swift")
        // The entry points stood as lists of closures in the view,
        // one per scope. They are gone; the view calls the rule.
        let builders = ["deckEntries", "musicDeckEntries", "audiobookDeckEntries", "artistDeckEntry"]
        #expect(Self.hits(builders, in: view).isEmpty, "ein Einstiegs-Bauer ist zurueck")
        #expect(Self.code(in: view).contains("SearchDeckTiles"))
        // Red probe: the checker would see the old form if it came back.
        #expect(Self.hits(builders, in: "private var musicDeckEntries: [DeckEntry] {")
                    == ["musicDeckEntries"])
    }

    @Test("Every hit kind has a named destination")
    func everyKindHasATarget() {
        // No chance result: the rule is exhaustive over the kind, and
        // this case runs each one once, so that a new kind does not lead
        // silently nowhere.
        let lookups = SearchLookups(item: { _ in true }, catalogHasParts: { _ in false },
                                    catalogKnows: { _ in true }, artistId: { _ in "a1" },
                                    artistKnown: { _ in true })
        for kind in SearchResult.Kind.allCases {
            let result = SearchResult(id: "id", kind: kind, title: "T")
            #expect(SearchRouting.target(for: result, lookups: lookups) != .unavailable,
                    "eine Trefferart ohne Ziel: \(kind.rawValue)")
        }
    }

    /// Rule 3 at the search door: a failure is not an empty result.
    /// Measured: the artist drill stood empty without a server and without a word,
    /// and the same form stood at the playlists and at the genre shows.
    @Test("The search door does not turn a failure into an empty list, and every surface says it in one sentence", .needsTheSources)
    func aFailureIsNoEmptyList() throws {
        let door = try Self.source("Sources/ViewModels/SearchDoor.swift")
        #expect(!door.contains("?? []"), "a failed question of the door turns into an empty list again")
        for signature in ["static func artists() async -> [MusicArtist]?",
                          "static func playlists() async -> [MusicPlaylist]?",
                          "static func topShows(genreId: Int, limit: Int = 30) async -> [PodcastSearchResult]?"] {
            #expect(door.contains(signature), "\(signature) no longer tells a failure from none")
        }
        let screen = try Self.source("Sources/Views/SearchScreen.swift")
        for sentence in ["Artists could not be loaded.", "Playlists could not be loaded.", "Shows could not be loaded."] {
            #expect(screen.contains("drill.append(.failed(") && screen.contains("\"\(sentence)\""),
                    "the failure of this question says nothing: \(sentence)")
        }
        #expect(screen.components(separatedBy: "drill.append(.failed(").count - 1 == 3,
                "every question of the door has its sentence")
    }

    /// Rule 3 in full: the failure is in the log with a reason, and the page
    /// offers „Erneut versuchen", which asks the same question once more.
    @Test("The search door logs every failure with a reason, and the error page asks again on request", .needsTheSources)
    func aFailureIsLoggedAndCanBeRetried() throws {
        let door = try Self.source("Sources/ViewModels/SearchDoor.swift")
        for question in ["artists", "playlists", "genreShows"] {
            #expect(door.contains("logFailure(\"\(question)\", error)"), "\(question) fails without a log line")
        }
        let log = try #require(functionBody(of: "private static func logFailure(", in: door))
        #expect(log.contains("Logger.") && log.contains("FailureReason.of(error)"), "the line does not name the reason")
        let screen = try Self.source("Sources/Views/SearchScreen.swift")
        let failed = try #require(screen.range(of: "case .failed(_, let sentence, let retry):"))
        #expect(screen[failed.upperBound...].prefix(500).contains("RetryPill(identifier: \"search-drill-retry\")"), "the failure page offers no retry")
        let ask = try #require(functionBody(of: "private func ask(again retry: SearchDeckRetry) {", in: screen))
        for retry in ["case .artists: go(to: .artists)", "case .playlists: go(to: .playlists)",
                      "case .podcastGenre(let genre): openPodcastGenre(genre)"] {
            #expect(ask.contains(retry), "a retry does not ask its own question: \(retry)")
        }
    }
}
#endif
