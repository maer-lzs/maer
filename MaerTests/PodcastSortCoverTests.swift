// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A show's sort holds, an episode without a picture shows the show's, and
/// an image view never shows the picture of an address it left.
struct PodcastSortCoverTests {
    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return SyncContractFenceTests.stripped(try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8))
    }

    // MARK: - The cover

    @Test("Folgen-Cover: ein leeres Bild ist keines, dann gilt das Sendungsbild")
    func anEmptyImageIsNoImage() {
        #expect(PodcastCover.source(episodeImage: "", showArtwork: "https://s/show.jpg") == "https://s/show.jpg")
        #expect(PodcastCover.source(episodeImage: "  \n", showArtwork: "https://s/show.jpg") == "https://s/show.jpg")
        #expect(PodcastCover.source(episodeImage: nil, showArtwork: "https://s/show.jpg") == "https://s/show.jpg")
        #expect(PodcastCover.source(episodeImage: "https://s/ep.jpg", showArtwork: "https://s/show.jpg") == "https://s/ep.jpg")
        #expect(PodcastCover.source(episodeImage: "", showArtwork: "") == nil, "then the placeholder, honestly")
        #expect(PodcastCover.present("") == nil)
    }

    @Test("Folgen-Cover: kein Leser waehlt das Bild mehr mit ??, und der Import von PodcastIndex speichert kein leeres")
    func everyReaderAsksTheRule() throws {
        var all = ""
        for file in ProjectFileIntegrityTests.sourceFiles() {
            all += SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8)) + "\n"
        }
        #expect(all.contains("PodcastCover.source("), "the precondition: the sources were read")
        #expect(all.components(separatedBy: "imageURL ?? ").count - 1 == 0,
                "a reader picks the episode image with ?? and an empty one wins again")
        let subscriptions = try Self.source("Sources/Providers/PodcastSubscriptions.swift")
        #expect(subscriptions.contains("imageURL: PodcastCover.present(pi.image)"))
        #expect(!subscriptions.contains("imageURL: pi.image"))
    }

    // MARK: - The sort

    @Test("Sortierung: gespeichert und gelesen unter derselben Kennung; der Zustand entscheidet, ob gelesen wird")
    func theSortIsReadWhereItIsWritten() throws {
        let suite = "podcastsort-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var oldestFirst = PodcastShowPreferences.default
        oldestFirst.newestFirst = false
        oldestFirst.save(showId: "rss:abc", mode: .subscribed, defaults: defaults)
        #expect(PodcastShowPreferences.load(showId: "rss:abc", mode: .subscribed, defaults: defaults).newestFirst == false)
        // A page that appears before the stores loaded reads as browsed and
        // gets the default; only reading again once it is subscribed finds
        // the choice. That is why the page reads per id AND state.
        #expect(PodcastShowPreferences.load(showId: "rss:abc", mode: .browsed, defaults: defaults).newestFirst
                == PodcastShowPreferences.default.newestFirst)
        // Another key does not find it: the reason the page reads and
        // writes under ONE id.
        #expect(PodcastShowPreferences.load(showId: "https://feed.example/rss", mode: .subscribed,
                                            defaults: defaults).newestFirst == PodcastShowPreferences.default.newestFirst)
    }

    @Test("Sortierung: die Sendungsseite liest und schreibt nur unter preferencesId und liest bei jedem Wechsel neu")
    func theShowPageUsesOneId() throws {
        let page = try Self.source("Sources/Views/Podcasts/PodcastShowView.swift")
        #expect(page.components(separatedBy: "PodcastShowPreferences.load(").count - 1 == 1)
        #expect(page.contains("PodcastShowPreferences.load(showId: preferencesId, mode: mode)"))
        // Two writes: the filter button directly, the sheet's choices through
        // the shared binding rule, both under the one id and both through
        // `store`, which says the change to the choice family. A bare `save`
        // on the page would keep the choice on this device. The filter button
        // names its one choice, so it writes nothing else.
        #expect(page.components(separatedBy: "preferences.store(\\.unplayedOnly, showId: preferencesId, mode: mode)").count - 1 == 1)
        #expect(page.contains("PodcastShowPreferences.binding(path, of: $preferences, showId: preferencesId, mode: mode)"))
        #expect(page.components(separatedBy: ".store(").count - 1 == 1, "no write under another id")
        #expect(page.components(separatedBy: ".save(showId:").count - 1 == 0, "no write that stays on the device")
        #expect(page.components(separatedBy: "PodcastShowPreferences.binding(").count - 1 == 1, "no binding under another id")
        #expect(page.contains(".task(id: preferencesSlot)"), "read again when the id or the state changes")
        #expect(!page.contains("seedShow?.id ?? feedURL"), "the old read key")
    }

    // MARK: - The image of a previous address

    @Test("Bild: eine Ladung, deren Adresse gewechselt hat, schreibt ihr Bild nicht mehr")
    func aCancelledLoadWritesNothing() throws {
        let view = try Self.source("Sources/Views/CachedAsyncImage.swift")
        let call = try #require(view.range(of: "await Artwork.image("))
        let after = view[call.upperBound...].split(separator: "\n").dropFirst()
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        #expect(after?.contains("guard !Task.isCancelled else { return }") == true,
                "the first line after the answer asks whether this load still counts")
        let guardAt = try #require(view.range(of: "guard !Task.isCancelled else { return }"))
        let write = try #require(view.range(of: "uiImage = answer.image"))
        #expect(guardAt.lowerBound < write.lowerBound, "before anything is written")
    }
}
#endif
