// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Not a field is checked, but the
/// PROCEDURE. A stored show with FEWER episodes and set
/// store facts against a fresh one with MORE. Does each of them survive?
///
/// If the list of store facts grows, this test must grow with it. That is
/// exactly what it is for: with the old procedure someone had to remember it
/// every time, and at the second field nobody did.
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

    @Test("shared cases: merge carries four cases")
    func mergeCasesLoaded() {
        #expect(Self.merges.count == 4)
    }

    @Test("shared cases: every store fact survives the union, per case as the file says", arguments: merges)
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
