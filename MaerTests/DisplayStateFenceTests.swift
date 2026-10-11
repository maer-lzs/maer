// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// What a surface shows says what is true: an unknown running time stays
/// unknown, a lasting refusal shows on every lock, and a state a picture
/// carries (the heart, the running ring) is named for VoiceOver too.
struct DisplayStateFenceTests {
    private func code(_ path: String) throws -> String {
        SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
    }

    @Test("eine Playlist ohne angegebene Laufzeit zeigt keine 0:00, sondern nur die Titelzahl", .needsTheSources)
    func anUnknownRunningTimeStaysUnknown() throws {
        #expect(PlaylistPresentation.knownSeconds(nil) == nil, "no running time became a number")
        #expect(PlaylistPresentation.knownSeconds(0) == nil && PlaylistPresentation.knownSeconds(0.4) == nil,
                "nothing above zero became 0:00")
        #expect(PlaylistPresentation.knownSeconds(4332.7) == 4332)
        let card = try code("Sources/Views/Music/PlaylistCard.swift")
        #expect(card.contains("durationSeconds: PlaylistPresentation.knownSeconds(playlist.duration)"),
                "the server card reads the running time another way")
        #expect(!card.contains("Int(playlist.duration ?? 0)"), "the unknown running time turns into zero again")
    }

    /// Which lock a feed carries is asked in one place
    /// (`PodcastSubscriptions.lock(feedURL:)`); every surface hands its
    /// answer on, and no lock has a default a surface could fall back to.
    @Test("jedes Schloss fragt die dauerhafte Verweigerung, nicht nur die Sendungs-Kacheln", .needsTheSources)
    func everyLockAsksTheRefusal() throws {
        var deciders: [String] = []
        var handWritten: [String] = []
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]) {
            let code = StockDriftTests.squeezed(SyncContractFenceTests.stripped(text))
            if code.contains("FeedLock.of(") { deciders.append(name) }
            guard name != "PremiumBadge.swift", name != "FeedLock.swift" else { continue }
            for literal in ["lock:.premium", "lock:.refused", "FeedLock.premium", "FeedLock.refused", "premiumLock(.premium", "premiumLock(.refused"]
            where code.contains(literal) {
                handWritten.append("\(name): \(literal)")
            }
        }
        #expect(deciders == ["PodcastSubscriptions.swift"], "the lock is decided beside the one question: \(deciders)")
        #expect(handWritten.isEmpty, "a surface writes a lock instead of asking: \(handWritten)")
        let badge = StockDriftTests.squeezed(try code("Sources/Views/Podcasts/PremiumBadge.swift"))
        let tile = StockDriftTests.squeezed(try code("Sources/Views/MediaTile.swift"))
        #expect(badge.contains("letlock:FeedLock") && !badge.contains("lock:FeedLock="), "the badge has a default lock")
        #expect(tile.contains("letlock:FeedLock") && !tile.contains("lock:FeedLock="), "the tile has a default lock")
        // The flag form, not the word: the badge's `case .refused:` stays.
        #expect(!badge.contains("refused:Bool") && !tile.contains("isRefused:Bool") && !tile.contains("isPremium:Bool"),
                "a separate premium or refusal flag came back")
        let grid = StockDriftTests.squeezed(try code("Sources/Views/Podcasts/LatestEpisodesGrid.swift"))
        #expect(grid.contains("subs.lock(feedURL:") && grid.contains("lock:locks[item.id]??.none"),
                "Latest Episodes does not hand on the one answer")
        let card = StockDriftTests.squeezed(try code("Sources/Views/Podcasts/PodcastComponents.swift"))
        #expect(card.contains("PremiumLockBadge(lock:PodcastSubscriptions.shared.lock("), "the Continue card does not ask the one question")
        #expect(card.components(separatedBy: ".premiumLock(lock)").count == 3, "a show tile does not draw the lock it was handed")
        let list = StockDriftTests.squeezed(try code("Sources/Views/PodcastsView.swift"))
        #expect(list.components(separatedBy: "lock:subs.lock(feedURL:").count == 7, "a show tile caller does not ask the one question")
        // The rule itself: a lasting refusal wins over premium.
        #expect(FeedLock.of(isPremium: true, isRefused: true) == .refused)
        #expect(FeedLock.of(isPremium: true, isRefused: false) == .premium)
        #expect(FeedLock.of(isPremium: false, isRefused: true) == .refused)
        #expect(FeedLock.of(isPremium: false, isRefused: false) == .none)
    }

    /// Tiles that name no lock by hand, per file; the stock is the count. A
    /// new surface that shows a feed and writes `.none` shows up here.
    static let noLockStock: [String: (count: Int, reason: String)] = [
        "FeedArtwork.swift": (1, "catalog titles, no feed"),
        "HomeView.swift": (3, "a book pick has no feed; the show pick and the episode pick hold a feed, whether they carry the lock is open as a product question"),
        "MixedMediaPage.swift": (2, "a book has no feed; the other title may be an episode, open as a product question"),
        "PodcastComponents.swift": (1, "a search result holds its feed, open as a product question"),
        "PodcastsView.swift": (1, "the Continue page of episodes, whose card asks the lock; open as a product question"),
        "SearchScreen.swift": (1, "the show grid of the search holds the feed, open as a product question"),
    ]

    @Test("jede Kachel, die das Schloss von Hand auf keins setzt, ist je Datei gezaehlt", .needsTheSources)
    func everyHandWrittenNoLockIsCounted() throws {
        var counts: [String: Int] = [:]
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]) {
            let code = StockDriftTests.squeezed(SyncContractFenceTests.stripped(text))
            let found = code.components(separatedBy: "lock:.none").count - 1
            if found > 0 { counts[name] = found }
        }
        let drift = StockDrift.findings(counts: counts, stock: Self.noLockStock.mapValues(\.count))
        #expect(drift.isEmpty, "a tile names no lock unseen, or the stock stands above the count: \(drift)")
    }

    /// The heart and the running ring carry their state for VoiceOver, and
    /// the ring is one control.
    @Test("das Herz sagt Namen und Zustand, der laufende Ring ist ein Bauteil mit Namen und Fortschritt", .needsTheSources)
    func picturedStatesAreNamed() throws {
        let album = try code("Sources/Views/Music/MusicAlbumView.swift")
        let heart = try #require(album.range(of: "Image(systemName: starred ? \"heart.fill\" : \"heart\")"),
                                 "the heart is gone or spelled another way")
        let after = album[heart.upperBound...].prefix(400)
        #expect(after.contains(".accessibilityLabel(Text(\"Favorite\"))"), "the heart has no name")
        #expect(after.contains(".accessibilityAddTraits(starred ? .isSelected : [])"), "the heart does not say whether it is on")
        var rings: [String] = []
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources/Views"]) where name != "DownloadRing.swift" {
            // A bare ring, not the control that wraps it nor the shape beneath.
            let code = SyncContractFenceTests.stripped(text)
            let bareRings = code.components(separatedBy: "DownloadRing(fraction:").count
                - code.components(separatedBy: "CancelDownloadRing(fraction:").count
                - code.components(separatedBy: "UnifiedDownloadRing(fraction:").count + 1
            if bareRings > 0 { rings.append(name) }
        }
        #expect(rings.isEmpty, "a ring is built beside the one control: \(rings)")
        let ring = try code("Sources/Views/DownloadRing.swift")
        #expect(ring.contains(".accessibilityLabel(Text(\"Cancel Download\"))") && ring.contains(".accessibilityValue("),
                "the ring control has no name or no progress")
    }

    /// A state a glyph alone carries is named: the offline mark wherever it
    /// stands without a text beside it, the subscribed check, the actions
    /// menu of a playlist.
    @Test("ein Zustand, den nur ein Zeichen traegt, hat einen Namen: Offline-Zeichen, Abo-Haken, Aktionen-Menue", .needsTheSources)
    func glyphStatesAreNamed() throws {
        var unnamed: [String] = []
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources/Views"]) {
            let code = SyncContractFenceTests.stripped(text)
            for part in code.components(separatedBy: "Image(systemName: \"wifi.slash\")").dropFirst() {
                let near = part.prefix(400)
                if !near.contains(".accessibilityLabel(") && !near.contains("Text(\"") { unnamed.append(name) }
            }
        }
        #expect(unnamed.isEmpty, "an offline mark without a name or a text beside it: \(unnamed)")
        let components = try code("Sources/Views/Podcasts/PodcastComponents.swift")
        let tight = StockDriftTests.squeezed(components)
        let check = try #require(tight.range(of: "Image(systemName:\"checkmark.circle.fill\").foregroundStyle(.white,.green)"),
                                 "the subscribed check is gone or spelled another way")
        #expect(tight[check.upperBound...].prefix(160).contains(".accessibilityLabel(Text(\"Subscribed\"))"),
                "the subscribed check has no name")
        #expect(!components.contains("Image(systemName: \"wifi.slash\")"), "the show tile draws its own offline mark again")
        let album = try code("Sources/Views/Music/MusicAlbumView.swift")
        let menu = try #require(album.range(of: "label: { Image(systemName: \"ellipsis.circle\") }"), "the actions menu is gone")
        #expect(album[menu.upperBound...].prefix(120).contains(".accessibilityLabel(Text(\"Actions\"))"), "the actions menu has no name")
    }
}
#endif
