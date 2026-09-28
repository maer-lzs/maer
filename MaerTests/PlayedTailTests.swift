// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Fast fertig gilt als gehoert. Eine Regel, zwei Fragen: `isPlayed`
/// mit der Schwelle der Person fuer alles Sichtbare, `reachedEnd` (die
/// Sekunde) fuer alles, was an einen Server geht oder eine Marke repariert.
struct PlayedTailTests {
    @Test("Die Tabelle: Laenge 10 min, 60 min, 10 h; Stand 1 s, 30 s, 59 s, 61 s, 5 min vor Schluss; je Einstellung")
    func theTable() {
        let offsets: [Double] = [1, 30, 59, 61, 300]
        // Played or not, per tail, in the order of the offsets above. The
        // tail covers at most a tenth of the length, so a 10 min episode
        // never counts as played more than 60 s before its end.
        let long: [Double: [Bool]] = [
            0: [true, false, false, false, false],
            30: [true, true, false, false, false],
            60: [true, true, true, false, false],
            120: [true, true, true, true, false],
            300: [true, true, true, true, true],
        ]
        let tenMinutes: [Double: [Bool]] = [
            0: [true, false, false, false, false],
            30: [true, true, false, false, false],
            60: [true, true, true, false, false],
            120: [true, true, true, false, false],
            300: [true, true, true, false, false],
        ]
        for length in [600.0, 3_600, 36_000] {
            for (tail, row) in (length == 600 ? tenMinutes : long) {
                for (offset, played) in zip(offsets, row) {
                    let stored = [length - offset, 1_000, length]
                    #expect(ProgressMark.isPlayed(stored: stored, currentDuration: length, tail: tail) == played,
                            "length \(length), \(offset) s before the end, tail \(tail)")
                    // The true end does not move with the choice.
                    #expect(ProgressMark.reachedEnd(stored: stored, currentDuration: length) == (offset <= 1))
                    #expect(SyncRules.isFinished(currentTime: length - offset, duration: length) == (offset <= 1),
                            "a server hears finished only at the end")
                }
            }
        }
        #expect(PlayedTail.choices == [0, 30, 60, 120, 300] && PlayedTail.standard == 60)
    }

    @Test("Ein kurzer Titel gilt nicht nach der Haelfte als gehoert: die Schwelle ist hoechstens ein Zehntel")
    func shortItemsAreNotPlayedEarly() {
        #expect(!ProgressMark.withinTail(position: 60, duration: 120, tail: 60), "two-minute news at its first minute")
        #expect(ProgressMark.withinTail(position: 109, duration: 120, tail: 60), "the last twelve seconds")
        #expect(!ProgressMark.withinTail(position: 50, duration: 100, tail: 60))
    }

    @Test("Nie noch 0 Min.: der Rest rundet auf")
    func neverZeroMinutes() {
        #expect(ProgressMark.minutesLeft(0) == 0)
        #expect(ProgressMark.minutesLeft(1) == 1)
        #expect(ProgressMark.minutesLeft(59) == 1)
        #expect(ProgressMark.minutesLeft(60) == 1)
        #expect(ProgressMark.minutesLeft(61) == 2)
        #expect(ProgressMark.minutesLeft(3_599) == 60)
        // The book text asks the same rounding.
        let book = BookProgress(fraction: 0.999, isFinished: false, lastUpdate: 1, currentTime: 3_560)
        #expect(book.remainingText(bookDuration: 3_600) == String(localized: "\(1) min left"))
    }

    @Test("Zwei Geraete, verschiedene Schwelle: dieselbe Marke, keiner schreibt, keiner zeigt 0 Min.")
    func twoDevicesReadTheSameMark() {
        let mark: [Double] = [3_560, 1_000, 3_600]
        #expect(ProgressMark.state(stored: mark, currentDuration: 3_600, tail: 60) == .played)
        guard case .inProgress(_, let remaining) = ProgressMark.state(stored: mark, currentDuration: 3_600, tail: 0) else {
            Issue.record("with the tail off the episode is still in progress")
            return
        }
        #expect(ProgressMark.minutesLeft(remaining) == 1, "40 s left reads 1 min, never 0")
    }

    @Test("Der Bestand wird nicht umgeschrieben: die Reparatur traegt nur am echten Ende eine Dauer ein")
    func theStockIsOnlyRead() {
        // 30 s before the end counts as played (tail 60), but was not written
        // against that duration; a repair there would guess.
        #expect(ProgressMark.supplementingFinished([3_570, 1_000], duration: 3_600) == nil)
        #expect(ProgressMark.supplementingFinished([3_600, 1_000], duration: 3_600) == [3_600, 1_000, 3_600])
        // A book within the tail counts as finished; its flag and fraction stay.
        let near = BookProgress(fraction: 0.99, isFinished: false, lastUpdate: 1, currentTime: 35_700)
        let judged = near.judged(duration: 36_000, tail: 300)
        #expect(judged.countsAsFinished && !judged.isFinished && judged.fraction == 0.99)
        #expect(!near.judged(duration: 36_000, tail: 60).countsAsFinished, "5 min left with a 1 min tail")
        #expect(!near.countsAsFinished, "not judged, nothing changes")
    }

    @Test("Ein alter Plattenstand ohne das neue Feld liest sich weiter")
    func oldDiskCacheDecodes() throws {
        let literal = Data(#"{"fraction":0.5,"isFinished":false,"lastUpdate":1000,"currentTime":1800}"#.utf8)
        let decoded = try JSONDecoder().decode(BookProgress.self, from: literal)
        #expect(decoded.withinTail == nil && decoded.fraction == 0.5)
    }

    @Test("Der Serverstand einer ABS-Folge kennt die Schwelle")
    func serverStateHasTheTail() {
        #expect(ProgressMark.serverState(isFinished: false, fraction: 0.99, duration: 3_600, tail: 60) == .played,
                "36 s left")
        #expect(ProgressMark.serverState(isFinished: false, fraction: 0.99, duration: 3_600, tail: 0).phase == .inProgress)
        #expect(ProgressMark.serverState(isFinished: true, fraction: 0.1, duration: 3_600, tail: 0) == .played)
        #expect(ProgressMark.serverState(isFinished: false, fraction: 0, duration: 3_600, tail: 300) == .unplayed)
    }

    @Test("Die Wahl: Titel vor allgemein vor Grundwert; eine Folge liest ihre Sendung")
    func theLevels() throws {
        let suite = "played-tail-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        #expect(PlayedTail.seconds(forItemId: "rss:abc:ep1", defaults: defaults) == 60, "standard")
        defaults.set(30.0, forKey: PlayedTail.generalKey)
        #expect(PlayedTail.seconds(forItemId: "rss:abc:ep1", defaults: defaults) == 30, "general")
        defaults.set(300.0, forKey: PlayedTail.key("rss:abc"))
        #expect(PlayedTail.seconds(forItemId: "rss:abc:ep1", defaults: defaults) == 300, "the episode reads its show")
        #expect(PlayedTail.seconds(forItemId: "rss:other:ep1", defaults: defaults) == 30)
        defaults.set(0.0, forKey: PlayedTail.key("book-1"))
        #expect(PlayedTail.seconds(forItemId: "book-1", defaults: defaults) == 0, "a book reads its own")
        defaults.set(45.0, forKey: PlayedTail.key("book-2"))
        #expect(PlayedTail.seconds(forItemId: "book-2", defaults: defaults) == 30, "an unknown value falls back")
    }

    @Test("Die Wahl reist: allgemein und je Sendung oder Buch")
    func theChoiceTravels() {
        #expect(UserChoiceCatalog.statics[PlayedTail.generalKey] == .travels)
        #expect(UserChoiceCatalog.prefixes[PlayedTail.prefix] == .travels)
        #expect(UserChoiceCatalog.travelingScalars.contains(PlayedTail.generalKey))
        #expect(UserChoiceCatalog.travelingPrefixes.contains(PlayedTail.prefix))
        #expect(PodcastShowPreferences.travellingKeys(showId: "rss:abc").contains(PlayedTail.key("rss:abc")))
    }
}
#endif
