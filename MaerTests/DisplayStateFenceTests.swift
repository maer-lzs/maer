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
/// carries (the running ring) is named for VoiceOver too, and the favorite
/// entry says its state in words.
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
        #expect(card.contains("CardMarks(itemId:item.id,lock:PodcastSubscriptions.shared.lock("), "the Continue card does not ask the one question")
        #expect(card.components(separatedBy: "StandardCoverMarks(lock:lock").count == 3, "a show tile does not draw the lock it was handed")
        // The search view asks no store itself: its show grid draws the
        // locks the door asked with the deck.
        let search = StockDriftTests.squeezed(try code("Sources/Views/SearchScreen.swift"))
        let door = StockDriftTests.squeezed(try code("Sources/ViewModels/SearchDoor.swift"))
        #expect(search.contains("lock:deck.locks[show.feedURL]??.none") && door.contains("subs.lock(feedURL:"),
                "the show grid of the search does not draw the lock the door asked")
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
        "HomeView.swift": (1, "a book pick of Rediscover, no feed"),
        "MixedMediaPage.swift": (1, "a book, no feed"),
    ]

    /// Every spelling of a hand-written no-lock in squeezed code: short
    /// (`.none`) as the argument, through the modifier or as a typed value,
    /// and the long `FeedLock.none` wherever it stands (also a value handed
    /// on later: `let x = FeedLock.none`, then `lock: x`). The fallback of
    /// the one answer (`locks[id] ?? .none`) asks first and is not counted.
    nonisolated static func handWrittenNoLocks(_ squeezed: String) -> Int {
        ["lock:.none", "premiumLock(.none", ":FeedLock=.none", "FeedLock.none"]
            .reduce(0) { $0 + squeezed.components(separatedBy: $1).count - 1 }
    }

    @Test("jede Kachel, die das Schloss von Hand auf keins setzt, ist je Datei gezaehlt, kurz oder lang geschrieben", .needsTheSources)
    func everyHandWrittenNoLockIsCounted() throws {
        var counts: [String: Int] = [:]
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]) {
            let found = Self.handWrittenNoLocks(StockDriftTests.squeezed(SyncContractFenceTests.stripped(text)))
            if found > 0 { counts[name] = found }
        }
        let drift = StockDrift.findings(counts: counts, stock: Self.noLockStock.mapValues(\.count))
        #expect(drift.isEmpty, "a tile names no lock unseen, or the stock stands above the count: \(drift)")
    }

    @Test("der Zaehler der leeren Schloesser sieht jede Schreibweise, auch einen spaeter uebergebenen Wert, und nicht den Rueckfall der einen Antwort")
    func theNoLockCounterReads() {
        #expect(Self.handWrittenNoLocks("lock:.none,") == 1)
        #expect(Self.handWrittenNoLocks("lock:FeedLock.none,") == 1)
        #expect(Self.handWrittenNoLocks(".premiumLock(.none)") == 1)
        #expect(Self.handWrittenNoLocks(".premiumLock(FeedLock.none)") == 1)
        #expect(Self.handWrittenNoLocks("letx=FeedLock.none") == 1, "a value handed on later is not counted")
        #expect(Self.handWrittenNoLocks("letx:FeedLock=.none") == 1, "a typed short value is not counted")
        #expect(Self.handWrittenNoLocks("lock:locks[item.id]??.none") == 0, "the fallback of the one answer counts")
    }

    /// The favorite entry says in words which state it changes, and the
    /// running ring is one control with its name and progress.
    @Test("der Favoriten-Eintrag nennt den Zustand im Wort, der laufende Ring ist ein Bauteil mit Namen und Fortschritt", .needsTheSources)
    func picturedStatesAreNamed() throws {
        let album = try code("Sources/Views/Music/MusicAlbumView.swift")
        let entry = try #require(album.range(of: "if starred {\n                        Label(\"Remove Favorite\", systemImage: \"heart.slash\")"),
                                 "the favorite entry is gone or spelled another way")
        #expect(album[entry.upperBound...].prefix(200).contains("Label(\"Add Favorite\", systemImage: \"heart\")"),
                "the favorite entry does not name the other state")
        #expect(!album.contains("heart.fill"), "the heart stands as a picture alone again")
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
    /// stands without a text beside it, the subscribed check, the pages'
    /// actions menu.
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
        let check = try #require(tight.range(of: "Image(systemName:\"checkmark\").font("),
                                 "the subscribed check is gone or spelled another way")
        #expect(tight[check.upperBound...].prefix(200).contains(".accessibilityLabel(Text(\"Subscribed\"))"),
                "the subscribed check has no name")
        #expect(!components.contains("Image(systemName: \"wifi.slash\")"), "the show tile draws its own offline mark again")
        // The pages' one menu (`pageActions`).
        let head = try code("Sources/Views/DetailHeader.swift")
        let menu = try #require(head.range(of: "label: { Image(systemName: \"ellipsis.circle\") }"), "the actions menu is gone")
        #expect(head[menu.upperBound...].prefix(120).contains(".accessibilityLabel(Text(\"Actions\"))"), "the actions menu has no name")
    }
}
#endif
