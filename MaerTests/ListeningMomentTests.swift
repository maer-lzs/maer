// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// One moment per title, for the row that ranks it and the card that names
/// it. A title that plays is the newest thing there is.
struct ListeningMomentTests {
    static let now: Double = 1_800_000_000_000

    @Test("Der neuere der beiden Staende gewinnt, Sekunden und Millisekunden auf einer Uhr")
    func newerStandWinsOnOneClock() {
        #expect(ListeningMoment.of(local: Self.now, server: Self.now - 5_000) == Self.now)
        #expect(ListeningMoment.of(local: Self.now - 5_000, server: Self.now) == Self.now)
        // A server or a seed may hand over seconds.
        #expect(ListeningMoment.of(local: 0, server: Self.now / 1000) == Self.now)
        #expect(ListeningMoment.of(local: 0, server: 0) == 0)
    }

    @Test("Was laeuft, ist das Juengste: ein fremder Stand von eben schiebt es nicht nach hinten")
    func theRunningTitleStaysFirst() {
        // The running title's own stand is half a minute old (it is written
        // every thirty seconds), the other device's stand arrived a second
        // ago. Without the rule the running title lost its place.
        let running = ListeningMoment.of(local: Self.now - 30_000, server: 0, playingNowMs: Self.now)
        let foreign = ListeningMoment.of(local: 0, server: Self.now - 1_000)
        #expect(running > foreign)
        // Red probe: without the playing moment the row flips.
        #expect(ListeningMoment.of(local: Self.now - 30_000, server: 0) < foreign)
    }

    @Test("Die Beschriftung der Karte: laufend sagt laufend, sonst der Moment, sonst nichts")
    func theCardSaysWhatItKnows() {
        #expect(ListeningMoment.label(local: Self.now - 30_000, server: 0, playingNowMs: Self.now) == .playing)
        #expect(ListeningMoment.label(local: Self.now - 30_000, server: Self.now, playingNowMs: nil) == .at(Self.now))
        #expect(ListeningMoment.label(local: 0, server: 0, playingNowMs: nil) == .none)
    }

    @Test("Die Reihe der Startseite fragt dieselbe Uhr wie die Karten (eine Frage, keine zweite Rechnung)")
    func oneQuestionForRowAndCard() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func code(_ path: String) throws -> String {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            return text.split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        // The cards ask the one rule, not their own arithmetic.
        for card in ["Sources/Views/BookFeaturedCard.swift", "Sources/Views/Podcasts/PodcastComponents.swift"] {
            #expect(try code(card).contains("ListeningMoment.label("), "\(card) asks the one rule")
        }
        // And the row hands the playing moment in, on every stream.
        let home = try code("Sources/Views/HomeView.swift")
        #expect(home.components(separatedBy: "playingNowMs: PlayingNow.momentMs(").count - 1 >= 3,
                "books, episodes and music all know what plays")
        // The books stream itself, not just its neighbours: the statement
        // is "the row's own sources ask the one clock". Rediscover keeps
        // the plain stands on purpose (it looks for what PAUSED), so the
        // form is not forbidden, its place is what counts.
        let books = home.components(separatedBy: "let books = libraryViewModel.continueListening")
        #expect(books.count == 2, "one books stream")
        #expect(books[1].prefix(400).contains("playingNowMs: PlayingNow.momentMs("),
                "the books stream hands the playing moment in")
    }
}
#endif
