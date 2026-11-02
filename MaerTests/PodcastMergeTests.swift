// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Nicht ein Feld wird geprüft, sondern das
/// VERFAHREN. Eine gespeicherte Show mit WENIGER Folgen und gesetzten
/// Speicher-Tatsachen gegen eine frische mit MEHR. Überlebt jede davon?
///
/// Wächst die Liste der Speicher-Tatsachen, muss dieser Test mitwachsen. Genau
/// dafür ist er da: Beim alten Verfahren musste jedes Mal jemand daran denken,
/// und beim zweiten Feld hat niemand daran gedacht.
struct PodcastMergeTests {
    /// The cases live in `Fixtures/Shared/abos/merge.json`, read by Swift
    /// and Kotlin alike: every store fact (the show's origin, an episode's
    /// measured length mirrored into its duration) survives a refresh with
    /// more episodes and a thin parse with fewer, the survivor of a twin
    /// collapse keeps its address and the other's origin, and nothing is
    /// invented. The expected episode list is the whole result, in order:
    /// a fact that dies, an episode that vanishes, a length that appears
    /// from nowhere, each tears the case.
    nonisolated static let merges = SharedCases.cases("merge")

    /// A show as the file names it: title, origin, feedURL, episodes with
    /// guid, pubDate, duration and measuredDuration.
    private static func show(_ value: JSONValue) -> PodcastShow {
        let episodes = (value["episodes"]?.array ?? []).map { episode -> PodcastEpisode in
            let guid = episode["guid"]?.string ?? ""
            var e = PodcastEpisode(guid: guid, title: "E\(guid)", audioURL: "https://x/\(guid).mp3",
                                   pubDate: Double(episode["pubDate"]?.int ?? 0),
                                   duration: Double(episode["duration"]?.int ?? 0),
                                   description: nil, imageURL: nil, chaptersURL: nil)
            e.measuredDuration = episode["measuredDuration"]?.int.map(Double.init)
            return e
        }
        var s = PodcastShow(id: "a", title: value["title"]?.string ?? "", author: nil, artworkURL: nil,
                            description: nil, feedURL: value["feedURL"]?.string ?? "", episodes: episodes)
        s.origin = value["origin"]?.string
        return s
    }

    @Test("gemeinsame Faelle: merge traegt vier Faelle")
    func mergeCasesLoaded() {
        #expect(Self.merges.count == 4)
    }

    @Test("gemeinsame Faelle: jede Speicher-Tatsache ueberlebt die Vereinigung, je Fall wie die Datei sagt", arguments: merges)
    func everyStoreFactSurvivesAsTheFileSays(_ c: SharedCase) throws {
        let input = try c.value("input")
        let expect = try c.value("expect")
        let merged = PodcastIdentity.merge(Self.show(try #require(input["stored"])),
                                                Self.show(try #require(input["fresh"])))
        #expect(merged.title == expect["title"]?.string, "\(c.slug)")
        #expect(merged.origin == expect["origin"]?.string, "\(c.slug)")
        #expect(merged.feedURL == expect["feedURL"]?.string, "\(c.slug)")
        let episodes = JSONValue.array(merged.episodes.map {
            .object(["guid": .string($0.guid), "duration": .int(Int($0.duration)),
                     "measuredDuration": $0.measuredDuration.map { .int(Int($0)) } ?? .null])
        })
        #expect(episodes == expect["episodes"], "\(c.slug)")
    }
}
#endif
