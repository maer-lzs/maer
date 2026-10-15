// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// GOAL 3.0, Punkt 1: die Suchansicht ruft keinen Provider und entscheidet
/// kein Ziel. Beides lag vorher bei ihr: sie fragte den Musik-Provider und
/// das Podcast-Verzeichnis selbst, und wohin ein Treffer führt, entschied
/// `LibraryView`, ein Rufer, der mit Suchen nichts zu tun hat. Der Zaun
/// hält die Naht; die Rot-Probe steht im Test selbst, weil ein Zaun, der
/// nur „0 Verstöße" meldet, nichts beweist.
struct SearchDoorFenceTests {
    private static func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    /// Die Provider-Namen, die eine Suchfläche nie selbst kennen soll.
    private static let providerReaches = [
        "AppSession.shared",
        "ITunesDirectory(",
        "PodcastIndexDirectory(",
        "FreeCatalogProvider.shared",
        "RadioProvider.shared",
        "PodcastSubscriptions.shared",
    ]

    /// Der Code ohne Kommentarzeilen. Ein Zaun, der ueber Rohtext sucht,
    /// reisst sonst an der Begruendung, die erklaert, warum der Griff fort ist.
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

    @Test("Die Suchansicht fragt keinen Provider selbst", .needsTheSources)
    func theSearchViewAsksNoProvider() throws {
        #expect(Self.reaches(in: try Self.source("Sources/Views/SearchScreen.swift")).isEmpty)
        // Rot-Probe in beide Richtungen: der Prüfer sieht den Griff…
        #expect(Self.reaches(in: "let x = AppSession.shared.musicProvider") == ["AppSession.shared"])
        // …und einen Kommentar darüber sieht er NICHT (die Lehre aus dem
        // Zaun, der an seiner eigenen Begründung riss).
        #expect(Self.reaches(in: "// uses AppSession.shared.musicProvider").isEmpty)
    }

    @Test("Die Ansicht entscheidet kein Ziel mehr: kein switch über die Trefferart", .needsTheSources)
    func theViewDecidesNoTarget() throws {
        // `LibraryView` führt das Ziel aus, aber die ENTSCHEIDUNG steht in
        // `SearchRouting`. Erkennungsmerkmal ist der Griff auf die ART.
        let library = try Self.source("Sources/Views/LibraryView.swift")
        #expect(!library.contains("switch result.kind"))
        #expect(library.contains("SearchDoor.target"))
    }

    /// Was das Deck fuettert und wie es gebaut wird, gehoert hinter die Tuer.
    /// Vorher stand beides in der Ansicht: sie holte die Sendungen und die
    /// Alben selbst, gruppierte die eigene Bibliothek und schob die Arbeit
    /// selbst vom Hauptstrang.
    private static let deckReaches = [
        "PodcastAutoContinue.allShows",
        "LibraryViewModel.authorGroups",
        "LibraryViewModel.genreGroups",
        "Task.detached",
    ]

    @Test("Die Suchansicht baut das Deck nicht selbst", .needsTheSources)
    func theSearchViewDoesNotBuildTheDeck() throws {
        let view = try Self.source("Sources/Views/SearchScreen.swift")
        let found = Self.hits(Self.deckReaches, in: view)
        #expect(found.isEmpty, "die Ansicht baut wieder selbst: \(found)")
        // Und sie fragt die Tuer danach, statt gar nichts zu zeigen.
        #expect(Self.code(in: view).contains("SearchDoor.deck("))
        // Rot-Probe in beide Richtungen: der Pruefer saehe die alte Form…
        #expect(Self.hits(Self.deckReaches, in: "let shows = PodcastAutoContinue.allShows()")
                    == ["PodcastAutoContinue.allShows"])
        // …und einen Kommentar ueber die alte Form sieht er NICHT.
        #expect(Self.hits(Self.deckReaches, in: "// was PodcastAutoContinue.allShows()").isEmpty)
    }

    @Test("Die Ansicht entscheidet nicht, welche Kacheln ein Bereich hat", .needsTheSources)
    func theViewDoesNotDecideTheTiles() throws {
        let view = try Self.source("Sources/Views/SearchScreen.swift")
        // Die Einstiege standen als Listen von Verschluessen in der Ansicht,
        // je Bereich eine. Sie sind fort; die Ansicht ruft die Regel.
        let builders = ["deckEntries", "musicDeckEntries", "audiobookDeckEntries", "artistDeckEntry"]
        #expect(Self.hits(builders, in: view).isEmpty, "ein Einstiegs-Bauer ist zurueck")
        #expect(Self.code(in: view).contains("SearchDeckTiles"))
        // Rot-Probe: der Pruefer saehe die alte Form, wenn sie wiederkaeme.
        #expect(Self.hits(builders, in: "private var musicDeckEntries: [DeckEntry] {")
                    == ["musicDeckEntries"])
    }

    @Test("Jede Trefferart hat ein benanntes Ziel")
    func everyKindHasATarget() {
        // Kein Zufallsergebnis: die Regel ist erschöpfend über die Art, und
        // dieser Fall fährt jede einmal, damit eine neue Art nicht still
        // ins Leere führt.
        let lookups = SearchLookups(item: { _ in true }, catalogHasParts: { _ in false },
                                    catalogKnows: { _ in true }, artistId: { _ in "a1" },
                                    artistKnown: { _ in true })
        for kind in SearchResult.Kind.allCases {
            let result = SearchResult(id: "id", kind: kind, title: "T")
            #expect(SearchRouting.target(for: result, lookups: lookups) != .unavailable,
                    "eine Trefferart ohne Ziel: \(kind.rawValue)")
        }
    }

    /// Regel 3 an der Such-Tuer: ein Fehlschlag ist kein leeres Ergebnis.
    /// Gemessen: der Kuenstler-Drill stand ohne Server leer und ohne Wort,
    /// und dieselbe Form stand an den Playlists und an den Genre-Sendungen.
    @Test("Die Such-Tuer macht aus einem Fehlschlag keine leere Liste, und jede Flaeche sagt ihn in einem Satz", .needsTheSources)
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

    /// Regel 3 ganz: der Fehlschlag steht im Log mit Grund, und die Seite
    /// bietet „Erneut versuchen", das dieselbe Frage noch einmal stellt.
    @Test("Die Such-Tuer protokolliert jeden Fehlschlag mit Grund, und die Fehler-Seite fragt auf Wunsch erneut", .needsTheSources)
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
