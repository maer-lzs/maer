// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// Nicht ein Feld wird geprüft, sondern das
/// VERFAHREN. Eine gespeicherte Show mit WENIGER Folgen und gesetzten
/// Speicher-Tatsachen gegen eine frische mit MEHR. Überlebt jede davon?
///
/// Wächst die Liste der Speicher-Tatsachen, muss dieser Test mitwachsen. Genau
/// dafür ist er da: Beim alten Verfahren musste jedes Mal jemand daran denken,
/// und beim zweiten Feld hat niemand daran gedacht.
struct PodcastMergeTests {
    private func episode(_ n: Int, measured: Double? = nil) -> PodcastEpisode {
        var e = PodcastEpisode(guid: "g\(n)", title: "E\(n)",
                               audioURL: "https://x/\(n).mp3",
                               pubDate: Double(n), duration: 3_600,
                               description: nil, imageURL: nil, chaptersURL: nil)
        e.measuredDuration = measured
        if let measured { e.duration = measured }
        return e
    }

    private func show(_ episodes: [PodcastEpisode], title: String = "Titel",
                      origin: String? = nil) -> PodcastShow {
        var s = PodcastShow(id: "a", title: title, author: nil, artworkURL: nil,
                            description: nil, feedURL: "https://x/a", episodes: episodes)
        s.origin = origin
        return s
    }

    @Test("jede Speicher-Tatsache überlebt eine Auffrischung mit MEHR Folgen")
    func storeFactsSurviveARefresh() {
        // Gespeichert: zwei Folgen, eine davon mit gemessener Länge, dazu die
        // Pinchflat-Herkunft.
        let stored = show([episode(1, measured: 3_420), episode(2)],
                          title: "alt", origin: "pinchflat:tube.example")
        // Frisch geparst: fünf Folgen, keine Ahnung von beidem. Der Normalfall
        // bei der ersten großen Auffrischung.
        let fresh = show([episode(1), episode(2), episode(3), episode(4), episode(5)],
                         title: "neu")

        let merged = PodcastSubscriptions.merge(stored, fresh)

        // Speicher-Tatsache der SHOW
        #expect(merged.origin == "pinchflat:tube.example")
        // Speicher-Tatsache der FOLGE. Sie starb vorher unauffälliger, weil
        // es je Folge passierte.
        let one = merged.episodes.first { $0.guid == "g1" }
        #expect(one?.measuredDuration == 3_420)
        #expect(one?.duration == 3_420, "die beste bekannte Länge bleibt an duration gespiegelt")
        // Feed-Tatsache: die frische Seite gewinnt.
        #expect(merged.title == "neu")
        // Und die Folgenliste ist die Vereinigung, nicht die kleinere Seite.
        #expect(merged.episodes.count == 5)
    }

    @Test("ein dünnes Parsen leert den Zwischenspeicher nicht")
    func aThinParseNeverEmptiesTheCache() {
        let stored = show((1...5).map { episode($0, measured: $0 == 1 ? 3_420 : nil) })
        let fresh = show([episode(1)])
        let merged = PodcastSubscriptions.merge(stored, fresh)
        #expect(merged.episodes.count == 5, "die Vereinigung haelt, auch wenn frisch weniger bringt")
        #expect(merged.episodes.first { $0.guid == "g1" }?.measuredDuration == 3_420)
    }


    @Test("beim Zwillings-Falten behaelt der Ueberlebende seine Adresse")
    func collapseKeepsTheSurvivorsFeedFacts() {
        // Dieselbe Funktion traegt zwei Verwendungen: Auffrischen (frisch
        // gewinnt) und Zwillings-Falten (Ueberlebender gewinnt). Der Zaun
        // haelt die zweite fest. Sie ist beim Umbau einmal gekippt.
        var alt = show([episode(1, measured: 3_420)], title: "alt", origin: "pinchflat:tube.example")
        alt.feedURL = "https://x/a?freebie=OLD"
        var neu = show([episode(1), episode(2)], title: "neu")
        neu.feedURL = "https://x/a?freebie=NEW"
        let merged = PodcastSubscriptions.merge(alt, neu)
        #expect(merged.feedURL.contains("NEW"), "die Adresse des Ueberlebenden traegt den aktuellen Token")
        #expect(merged.origin == "pinchflat:tube.example", "die Herkunft des anderen geht NICHT verloren")
        #expect(merged.episodes.first { $0.guid == "g1" }?.measuredDuration == 3_420)
    }

    @Test("eine Speicher-Tatsache entsteht nicht aus dem Nichts")
    func nothingIsInvented() {
        let merged = PodcastSubscriptions.merge(show([episode(1)]), show([episode(1), episode(2)]))
        #expect(merged.origin == nil)
        #expect(merged.episodes.allSatisfy { $0.measuredDuration == nil })
        #expect(merged.episodes.allSatisfy { $0.duration == 3_600 },
                "ohne Messung bleibt die angekuendigte Dauer stehen")
    }
}
#endif
