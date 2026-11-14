// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A measurement, not a change: what the walks over the whole defaults
/// domain at a start cost at three sizes of the domain, apart for the
/// listening positions (`StandMirror.start`) and the choices
/// (`UserChoiceCloudSync.forgetRetired` and the collect of every
/// reconcile). The numbers stand in the test log (`E4RMESS`); the case
/// holds only that the measure ran over the domain it built.
///
/// The sizes, each from a number in the code or the measurement of
/// 18.10.2026 (22,000 titles, 500 shows, 2,000 books):
/// - empty: no key of these families;
/// - from the code: the rates that travel (`playbackRateCap`, 500), a
///   played tail per show and per book (`PlayedTail` belongs to a show or
///   a book, never to an episode), the seven other traveling families per
///   show (`PodcastShowPreferences.travellingKeys`) and the four local ones;
/// - upper bound: every title carries a rate and a played tail, as on
///   18.10.
@MainActor
@Suite(.serialized)
struct StartWalkMeasureTests {
    static let titles = 22_000
    static let shows = 500
    static let books = 2_000

    struct Size {
        let name: String
        let rates: Int
        let tails: Int
        let showFamilies: Bool
    }

    static let sizes = [
        Size(name: "empty", rates: 0, tails: 0, showFamilies: false),
        Size(name: "fromCode", rates: UserChoiceCatalog.playbackRateCap, tails: shows + books, showFamilies: true),
        Size(name: "upperBound", rates: titles, tails: titles, showFamilies: true),
    ]

    /// The local auto-download families per show.
    static let localShowPrefixes = ["podcastAutoDownload.", "podcastAutoDownloadSince.",
                                    "podcastAutoDownloadKeep.", "podcastAutoDownloadError."]

    @Test("Measurement: the walks over the defaults at the start, per size of the domain")
    func theWalksAtThreeSizes() throws {
        for size in Self.sizes {
            let suite = "e4rmess-\(size.name)-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            for index in 0..<size.rates { defaults.set(1.25, forKey: "playbackRate.rss:feed-\(index / 40):episode-\(index)") }
            for index in 0..<size.tails { defaults.set(30.0, forKey: "playedTail.feed:show-\(index)") }
            if size.showFamilies {
                for show in 0..<Self.shows {
                    for key in PodcastShowPreferences.travellingKeys(showId: "feed:show-\(show)") { defaults.set(1, forKey: key) }
                    for prefix in Self.localShowPrefixes { defaults.set(1, forKey: prefix + "feed:show-\(show)") }
                }
            }
            let keys = defaults.dictionaryRepresentation().count

            let positions = DefaultsBlockMeasureTests.timed { _ in
                _ = ListeningStore.legacyEntries(in: defaults)
                _ = ListeningStore.positions(in: defaults)
            }
            let retired = DefaultsBlockMeasureTests.timed { _ in
                _ = defaults.dictionaryRepresentation().keys.filter(UserChoiceCatalog.isRetired)
            }
            var collected = 0
            let choices = DefaultsBlockMeasureTests.timed { _ in
                collected = defaults.dictionaryRepresentation().keys.filter { key in
                    UserChoiceCatalog.travelingPrefixes.contains { key.hasPrefix($0) }
                }.count
            }
            for (walk, time) in [("positions", positions), ("retiredChoices", retired), ("choices", choices)] {
                print(String(format: "E4RMESS size=%@ keys=%d walk=%@ ms_median=%.1f ms_max=%.1f",
                             size.name, keys, walk, time.median, time.max))
            }
            #expect(keys >= size.rates + size.tails, "the precondition: the measure wrote the keys of size \(size.name)")
            #expect(collected >= size.rates + size.tails, "the walk of the choices did not see the keys of size \(size.name)")
        }
    }
}
#endif
