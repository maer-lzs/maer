// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// An open show page, its settings sheet and the sheet of the episode page
/// read a show's values again when another device changed one of them
/// (decided: the sheet always shows the stored state, also while open).
/// I1 they show it without reopening, I2 reading again writes and stamps
/// nothing, I3 an adoption for another show reads nothing.
struct PodcastShowAdoptionTests {

    @Test("Die Regel: eine Uebernahme beruehrt genau die fuenf reisenden Werte ihrer Sendung")
    func theRule() {
        let show = "feed:adopt-a"
        let keys = PodcastShowPreferences.travellingKeys(showId: show)
        #expect(keys.count == 5)
        for key in keys {
            #expect(PodcastShowPreferences.adoptionTouches([key], showId: show), "\(key) is this show's")
            #expect(!PodcastShowPreferences.adoptionTouches([key], showId: "feed:adopt-b"), "I3: another show reads nothing")
        }
        #expect(!PodcastShowPreferences.adoptionTouches([AppStorageKeys.playbackRate("rss:adopt-a:1")], showId: show),
                "a title's speed is not the show's")
        #expect(!PodcastShowPreferences.adoptionTouches(["radioFavorites", "recentSearches"], showId: show))
        #expect(!PodcastShowPreferences.adoptionTouches([], showId: show))
        #expect(PodcastShowPreferences.adoptedKeys(nil).isEmpty)
        #expect(PodcastShowPreferences.adoptedKeys(["keys": ["a", "b"]]) == ["a", "b"])
    }

    @Test("Die fuenf Schluessel sind genau die reisenden Familien je Sendung des Katalogs")
    func theKeysAreTheCatalogsFamilies() {
        let show = "feed:adopt-a"
        let perShow = Set(UserChoiceCatalog.travelingPrefixes.filter { $0.hasPrefix("podcast") }.map { $0 + show })
        #expect(!perShow.isEmpty, "the catalog names families per show, or the case measures nothing")
        #expect(PodcastShowPreferences.travellingKeys(showId: show) == perShow,
                "a family that starts to travel is read again on an open page, and none is read that does not travel")
    }

    @Test("Seite, Blatt und Blatt der Folgenseite lesen bei einer Uebernahme ihrer Sendung nach und schreiben dabei nichts", .needsTheSources)
    func theThreePlacesReadAgainAndWriteNothing() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let page = try String(contentsOf: root.appendingPathComponent("Sources/Views/Podcasts/PodcastShowView.swift"), encoding: .utf8)
        let sheet = try String(contentsOf: root.appendingPathComponent("Sources/Views/Podcasts/PodcastShowSettingsSheet.swift"), encoding: .utf8)
        let head = "publisher(for: .userChoicesAdopted)) {"
        #expect(page.components(separatedBy: head).count - 1 == 1, "the page listens once")
        #expect(sheet.components(separatedBy: head).count - 1 == 2, "the sheet and the episode page's entry listen")

        var handlers: [String] = []
        for text in [page, sheet] {
            var rest = Substring(text)
            while let at = rest.range(of: head) {
                let body = try #require(functionBody(of: head, in: String(rest[at.lowerBound...])))
                handlers.append(body)
                rest = rest[at.upperBound...]
            }
        }
        #expect(handlers.count == 3)
        let writes = ["store(", "save(", ".set(", "setPodcast", "noteChoice", "noteScalar", "removeObject"]
        for body in handlers {
            #expect(body.contains("PodcastShowPreferences.adoptionTouches("), "each asks the rule first")
            #expect(["PodcastShowPreferences.load(", "reloadFromStore()", "readPreferences()"].contains { body.contains($0) },
                    "and reads")
            #expect(!writes.contains { body.contains($0) }, "I2: the handler writes nothing: \(body)")
        }
        #expect(page.contains(".task(id: preferencesSlot) { readPreferences() }"), "the page opens and adopts through the same read")
        let read = try #require(functionBody(of: "private func readPreferences() {", in: page))
        #expect(!writes.contains { read.contains($0) }, "I2: the page's read writes nothing")
        let reload = try #require(functionBody(of: "private func reloadFromStore() {", in: sheet))
        #expect(!writes.contains { reload.contains($0) }, "I2: the sheet's read writes nothing")
        let appear = try #require(sheet.range(of: ".onAppear { reloadFromStore() }"))
        #expect(!appear.isEmpty, "opening and adopting read the same way")
    }
}
#endif
