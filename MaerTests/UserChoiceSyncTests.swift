// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The choice family's pure merge core: event-time semantics, tombstones,
/// never-set vs. deliberately-empty, pre-family stock at t = 0.
struct UserChoiceMergeTests {

    private func entry(_ v: UserChoiceValue?, _ t: Double) -> UserChoiceEntry {
        UserChoiceEntry(value: v, t: t)
    }

    @Test func newerCloudWinsAndNewerLocalPushes() {
        #expect(UserChoiceMerge.decide(local: entry(.string("a"), 100),
                                       cloud: entry(.string("b"), 200)) == .adopt)
        #expect(UserChoiceMerge.decide(local: entry(.string("a"), 300),
                                       cloud: entry(.string("b"), 200)) == .push(300))
    }

    @Test("Never set beats nothing — and loses against any statement")
    func neverSetSemantics() {
        #expect(UserChoiceMerge.decide(local: nil, cloud: nil) == .none)
        // A device that never chose adopts even pre-family stock (t = 0).
        #expect(UserChoiceMerge.decide(local: nil, cloud: entry(.string("x"), 0)) == .adopt)
        // A device without an entry never overwrites a set value.
        #expect(UserChoiceMerge.decide(local: entry(.string("x"), 0), cloud: nil) == .push(0))
    }

    @Test("A deliberate clear is a tombstone and beats an older value")
    func tombstoneSemantics() {
        // Local cleared later than the cloud value → the clear travels.
        #expect(UserChoiceMerge.decide(local: entry(nil, 500),
                                       cloud: entry(.string("x"), 200)) == .push(500))
        // Foreign clear is newer → adopt (value becomes absent locally).
        #expect(UserChoiceMerge.decide(local: entry(.string("x"), 200),
                                       cloud: entry(nil, 500)) == .adopt)
    }

    @Test("Pre-family stock (t = 0) loses against a real action")
    func stockLosesAgainstAction() {
        #expect(UserChoiceMerge.decide(local: entry(.string("old"), 0),
                                       cloud: entry(.string("new"), 1234)) == .adopt)
        #expect(UserChoiceMerge.decide(local: entry(.string("new"), 1234),
                                       cloud: entry(.string("old"), 0)) == .push(1234))
    }

    @Test("Equal values never write — equal stamps with different values keep local")
    func tieSemantics() {
        #expect(UserChoiceMerge.decide(local: entry(.string("x"), 100),
                                       cloud: entry(.string("x"), 100)) == .none)
        // Same value, cloud stamp newer: align the stamp only.
        #expect(UserChoiceMerge.decide(local: entry(.string("x"), 100),
                                       cloud: entry(.string("x"), 400)) == .adoptStampOnly)
        // Honest tie: both t = 0 with divergent stock. No winner invented.
        #expect(UserChoiceMerge.decide(local: entry(.string("a"), 0),
                                       cloud: entry(.string("b"), 0)) == .none)
    }

    @Test("Bool and Int do not blur through NSNumber")
    func valueTyping() {
        #expect(UserChoiceValue.from(plist: true) == .bool(true))
        #expect(UserChoiceValue.from(plist: 1) == .int(1))
        #expect(UserChoiceValue.from(plist: true) != UserChoiceValue.from(plist: 1))
        #expect(UserChoiceValue.from(plist: 1.5) == .double(1.5))
        #expect(UserChoiceValue.from(plist: ["a", "b"]) == .stringList(["a", "b"]))
        // Round-trip through the plist form survives.
        let entry = UserChoiceEntry(value: .stringList(["ch", "de"]), t: 42)
        #expect(UserChoiceEntry.from(plist: entry.plist) == entry)
        let tomb = UserChoiceEntry(value: nil, t: 7)
        #expect(UserChoiceEntry.from(plist: tomb.plist) == tomb)
    }

    @Test("Search merge: newest first, tombstones out, capped — t = 0 keeps local order")
    func searchMerge() {
        let merged = UserChoiceMerge.mergedSearches(
            elements: [
                ("alt1", UserChoiceEntry(value: .bool(true), t: 0)),
                ("alt2", UserChoiceEntry(value: .bool(true), t: 0)),
                ("neu", UserChoiceEntry(value: .bool(true), t: 900)),
                ("geloescht", UserChoiceEntry(value: nil, t: 950)),
                ("fremd", UserChoiceEntry(value: .bool(true), t: 500)),
            ].map { (term: $0.0, entry: $0.1) },
            localOrder: ["alt2", "alt1"], cap: 3)
        #expect(merged == ["neu", "fremd", "alt2"])
    }

    @Test("Favorites keep local order; adopted stations append, oldest first")
    func favoritesOrder() {
        let a = RadioStation(id: "radio:rb:a", name: "A", streamURL: "http://a")
        let b = RadioStation(id: "radio:rb:b", name: "B", streamURL: "http://b")
        let c = RadioStation(id: "radio:rb:c", name: "C", streamURL: "http://c")
        let d = RadioStation(id: "radio:rb:d", name: "D", streamURL: "http://d")
        let merged = UserChoiceMerge.favoritesAppending(
            local: [a, b],
            adopted: [(d, 900), (c, 100), (a, 50)])
        #expect(merged.map(\.id) == ["radio:rb:a", "radio:rb:b", "radio:rb:c", "radio:rb:d"])
    }

    @Test func overflowDropsOldestBeyondCap() {
        let keys = UserChoiceMerge.overflowKeys(
            entries: [("k1", 100), ("k2", 300), ("k3", 200), ("k4", 300)],
            cap: 2)
        // Newest two survive (t=300 pair, tie-broken by key). K1/k3 drop.
        #expect(Set(keys) == ["k1", "k3"])
        #expect(UserChoiceMerge.overflowKeys(entries: [("k1", 1)], cap: 2).isEmpty)
    }
}

/// The component against a fake cloud: two "devices" = two defaults suites +
/// one shared store. KVS does not run on the simulator, so THIS is the merge
/// proof; the device pair run is the acceptance step on real hardware.
@MainActor
final class UserChoiceFakeCloud: UserChoiceCloudStore {
    var storage: [String: Any] = [:]
    func dictionary(forKey key: String) -> [String: Any]? { storage[key] as? [String: Any] }
    func array(forKey key: String) -> [Any]? { storage[key] as? [Any] }
    func set(_ value: Any?, forKey key: String) { storage[key] = value }
    func synchronize() -> Bool { true }
    var dictionaryRepresentation: [String: Any] { storage }
    func removeObject(forKey key: String) { storage[key] = nil }
}

@MainActor
struct UserChoiceCloudSyncTests {

    private func device(_ cloud: UserChoiceFakeCloud, now: Double)
        -> (sync: UserChoiceCloudSync, defaults: UserDefaults, suite: String) {
        let suite = "choice-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        var clock = now
        let sync = UserChoiceCloudSync(defaults: defaults, cloud: cloud,
                                       syncEnabled: { true },
                                       now: { clock += 1; return clock })
        return (sync, defaults, suite)
    }

    private func cleanup(_ suite: String) {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    /// A server address that worked on A is offered on B under the address
    /// field; only address, service and date travel, and a forget travels
    /// as a tombstone. B connects to nothing by itself: the register is a
    /// suggestion, not a configuration.
    @Test("Eine bekannte Serveradresse reist A → B, ohne Zugangsdaten; Vergessen reist mit")
    func knownServerTravels() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        let b = device(cloud, now: 2000)
        defer { cleanup(a.suite); cleanup(b.suite) }

        KnownServers.remember("https://music.example", service: .subsonic, now: 1_700_000_000, defaults: a.defaults)
        a.sync.noteKnownServers()
        b.sync.reconcile()
        let offered = KnownServers.suggestions(for: .subsonic, defaults: b.defaults)
        #expect(offered.map(\.url) == ["https://music.example"])
        #expect(offered.first?.lastSuccessAt == 1_700_000_000)
        #expect(b.defaults.string(forKey: AppStorageKeys.subsonicServerURL) == nil,
                "the address is offered, not configured")
        // Nothing in the blob but address, service and date.
        let blob = cloud.storage[UserChoiceCloudSync.blobKey] as? [String: Any] ?? [:]
        let keys = blob.keys.filter { $0.hasPrefix(UserChoiceCatalog.knownServerPrefix) }
        #expect(keys == ["knownServer.subsonic|https://music.example"])
        for key in blob.keys {
            let lower = key.lowercased()
            #expect(!lower.contains("password") && !lower.contains("token") && !lower.contains("username"),
                    "a credential in the blob: \(key)")
        }
        // Forgotten on A: gone on B.
        KnownServers.forget(KnownServer(url: "https://music.example", service: .subsonic, lastSuccessAt: 0),
                            defaults: a.defaults)
        a.sync.noteKnownServers(removed: "subsonic|https://music.example")
        b.sync.reconcile()
        #expect(KnownServers.suggestions(for: .subsonic, defaults: b.defaults).isEmpty)
    }

    /// Absence is not deletion: the cloud carries an address B has not
    /// adopted yet; B signs in somewhere else in that window. The address
    /// must survive, because only a forget on a device may bury it.
    @Test("Ein Eintrag, den B noch nicht uebernommen hat, stirbt nicht an B's naechster Anmeldung")
    func absenceIsNotDeletion() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        let b = device(cloud, now: 2000)
        defer { cleanup(a.suite); cleanup(b.suite) }
        KnownServers.remember("https://y.example", service: .gpodder, now: 1_700_000_000, defaults: a.defaults)
        a.sync.noteKnownServers()
        // B has not reconciled; it signs in at Z.
        KnownServers.remember("https://z.example", service: .jellyfin, now: 1_700_000_500, defaults: b.defaults)
        b.sync.noteKnownServers()
        a.sync.reconcile()
        // Y survives on A (Z arrives beside it, not instead of it).
        #expect(KnownServers.all(defaults: a.defaults).contains { $0.url == "https://y.example" && $0.service == .gpodder })
        #expect(Set(KnownServers.all(defaults: a.defaults).map(\.url)) == ["https://y.example", "https://z.example"])
        b.sync.reconcile()
        #expect(Set(KnownServers.all(defaults: b.defaults).map(\.url)) == ["https://y.example", "https://z.example"])
        // Adopting writes nothing back: no ping-pong.
        let before = cloud.storage[UserChoiceCloudSync.blobKey] as? [String: Any] ?? [:]
        b.sync.noteKnownServers()
        let after = cloud.storage[UserChoiceCloudSync.blobKey] as? [String: Any] ?? [:]
        #expect(NSDictionary(dictionary: before).isEqual(to: after))
    }

    @Test("Zugangsdaten in der Adresse reisen nie: das Register merkt sich den Host")
    func userInfoNeverTravels() {
        #expect(KnownServers.normalized("https://name:geheim@abs.example/") == "https://abs.example")
        #expect(KnownServers.normalized("https://abs.example/") == "https://abs.example")
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        defer { cleanup(a.suite) }
        KnownServers.remember("https://name:geheim@abs.example", service: .audiobookshelf, defaults: a.defaults)
        a.sync.noteKnownServers()
        let blob = cloud.storage[UserChoiceCloudSync.blobKey] as? [String: Any] ?? [:]
        #expect(blob.keys.contains("knownServer.audiobookshelf|https://abs.example"))
        #expect(!blob.keys.contains { $0.contains("@") || $0.contains("geheim") })
    }

    @Test("A scalar choice travels A → B; B's never-set does not overwrite")
    func scalarTravels() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        let b = device(cloud, now: 2000)
        defer { cleanup(a.suite); cleanup(b.suite) }

        a.defaults.set("author", forKey: AppStorageKeys.librarySortOption)
        a.sync.noteScalar(key: AppStorageKeys.librarySortOption, value: "author")
        b.sync.reconcile()
        #expect(b.defaults.string(forKey: AppStorageKeys.librarySortOption) == "author")

        // B never chose anything else. A plain reconcile on A changes nothing.
        a.sync.reconcile()
        #expect(a.defaults.string(forKey: AppStorageKeys.librarySortOption) == "author")
    }

    @Test("The adoption echo does not re-stamp — a later foreign action still wins")
    func adoptionEchoDoesNotRestamp() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        let b = device(cloud, now: 2000)
        defer { cleanup(a.suite); cleanup(b.suite) }

        a.defaults.set("title", forKey: AppStorageKeys.podcastSortOption)
        a.sync.noteScalar(key: AppStorageKeys.podcastSortOption, value: "title")
        b.sync.reconcile()
        // The surface's onChange fires after adoption and re-notes the same
        // value. The note must align, not advance, the stamp.
        b.sync.noteScalar(key: AppStorageKeys.podcastSortOption, value: "title")
        let blob = cloud.storage[UserChoiceCloudSync.blobKey] as? [String: Any]
        let entry = UserChoiceEntry.from(plist: blob?[AppStorageKeys.podcastSortOption])
        #expect((entry?.t ?? -1) < 2000)   // still A's stamp, not B's clock
    }

    @Test("Pre-family stock travels at t = 0 and loses against a real action")
    func stockTravelsWeak() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        let b = device(cloud, now: 2000)
        defer { cleanup(a.suite); cleanup(b.suite) }

        // A holds an OLD, unstamped choice (pre-family build) …
        a.defaults.set("author", forKey: AppStorageKeys.librarySortOption)
        a.sync.reconcile()
        // … which reaches a device that never chose:
        b.sync.reconcile()
        #expect(b.defaults.string(forKey: AppStorageKeys.librarySortOption) == "author")
        // B now ACTS. The real action beats the stock everywhere.
        b.defaults.set("duration", forKey: AppStorageKeys.librarySortOption)
        b.sync.noteScalar(key: AppStorageKeys.librarySortOption, value: "duration")
        a.sync.reconcile()
        #expect(a.defaults.string(forKey: AppStorageKeys.librarySortOption) == "duration")
    }

    @Test("Deliberate clear travels as tombstone; never-set stays distinguishable")
    func clearTravels() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        let b = device(cloud, now: 2000)
        defer { cleanup(a.suite); cleanup(b.suite) }

        a.defaults.set("X", forKey: AppStorageKeys.radioRegionState)
        a.sync.noteScalar(key: AppStorageKeys.radioRegionState, value: "X")
        b.sync.reconcile()
        #expect(b.defaults.string(forKey: AppStorageKeys.radioRegionState) == "X")

        // B clears deliberately. A follows.
        b.defaults.removeObject(forKey: AppStorageKeys.radioRegionState)
        b.sync.noteScalar(key: AppStorageKeys.radioRegionState, value: nil)
        a.sync.reconcile()
        #expect(a.defaults.string(forKey: AppStorageKeys.radioRegionState) == nil)
    }

    @Test("Adopting a region clears the derived query-name cache")
    func regionAdoptionClearsQueryNames() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        let b = device(cloud, now: 2000)
        defer { cleanup(a.suite); cleanup(b.suite) }

        b.defaults.set(["Old Region", "Old Variant"], forKey: AppStorageKeys.radioRegionQueryNames)
        a.defaults.set("Bayern", forKey: AppStorageKeys.radioRegionState)
        a.sync.noteScalar(key: AppStorageKeys.radioRegionState, value: "Bayern")
        b.sync.reconcile()
        #expect(b.defaults.string(forKey: AppStorageKeys.radioRegionState) == "Bayern")
        #expect(b.defaults.array(forKey: AppStorageKeys.radioRegionQueryNames) == nil)
    }

    @Test("Favorites merge element-wise, keep local order, tombstone removes")
    func favoritesTravel() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        let b = device(cloud, now: 2000)
        defer { cleanup(a.suite); cleanup(b.suite) }

        let x = RadioStation(id: "radio:rb:x", name: "X", streamURL: "http://x")
        let y = RadioStation(id: "radio:rb:y", name: "Y", streamURL: "http://y")
        let z = RadioStation(id: "radio:rb:z", name: "Z", streamURL: "http://z")

        RadioStore.replaceFavorites([x, y], defaults: a.defaults)
        a.sync.noteFavorite(x, added: true)
        a.sync.noteFavorite(y, added: true)
        RadioStore.replaceFavorites([z], defaults: b.defaults)
        b.sync.noteFavorite(z, added: true)

        a.sync.reconcile()
        b.sync.reconcile()
        // B keeps its own order first, adopted append in event order.
        #expect(RadioStore.favorites(defaults: b.defaults).map(\.id)
                == ["radio:rb:z", "radio:rb:x", "radio:rb:y"])
        a.sync.reconcile()
        #expect(RadioStore.favorites(defaults: a.defaults).map(\.id)
                == ["radio:rb:x", "radio:rb:y", "radio:rb:z"])

        // Unfavorite on A removes on B. And does not resurrect.
        RadioStore.replaceFavorites([y, z], defaults: a.defaults)
        a.sync.noteFavorite(x, added: false)
        b.sync.reconcile()
        #expect(!RadioStore.favorites(defaults: b.defaults).map(\.id).contains("radio:rb:x"))
        b.sync.reconcile()
        #expect(!RadioStore.favorites(defaults: b.defaults).map(\.id).contains("radio:rb:x"))
    }

    @Test("Recent searches: union by event time, explicit remove travels")
    func searchesTravel() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        let b = device(cloud, now: 2000)
        defer { cleanup(a.suite); cleanup(b.suite) }

        a.defaults.set(["dlf"], forKey: RecentSearches.storageKey)
        a.sync.noteSearch("dlf", removed: false)
        b.defaults.set(["zeit"], forKey: RecentSearches.storageKey)
        b.sync.noteSearch("zeit", removed: false)

        a.sync.reconcile()
        #expect(Set(RecentSearches.list(defaults: a.defaults)) == ["dlf", "zeit"])
        b.sync.reconcile()
        #expect(Set(RecentSearches.list(defaults: b.defaults)) == ["dlf", "zeit"])

        // Removing on B travels to A.
        b.defaults.set(["dlf"], forKey: RecentSearches.storageKey)
        b.sync.noteSearch("zeit", removed: true)
        a.sync.reconcile()
        #expect(RecentSearches.list(defaults: a.defaults) == ["dlf"])
    }

    @Test("The standby pointer travels — but never onto a finished item")
    func standbyPointerGuard() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        let b = device(cloud, now: 2000)
        defer { cleanup(a.suite); cleanup(b.suite) }

        a.defaults.set("rss:feed:ep1", forKey: AppStorageKeys.lastPlayedItemId)
        a.sync.noteScalar(key: AppStorageKeys.lastPlayedItemId, value: "rss:feed:ep1")

        // B knows the episode as FINISHED by numbers. Adoption is refused.
        b.defaults.set([3600.0, 1000.0, 3600.0],
                       forKey: AppStorageKeys.localPosition("rss:feed:ep1"))
        b.sync.reconcile()
        #expect(b.defaults.string(forKey: AppStorageKeys.lastPlayedItemId) == nil)

        // Unfinished on a third device: adoption goes through.
        let c = device(cloud, now: 3000)
        defer { cleanup(c.suite) }
        c.sync.reconcile()
        #expect(c.defaults.string(forKey: AppStorageKeys.lastPlayedItemId) == "rss:feed:ep1")
    }

    @Test("Legacy premium keys are read on EVERY reconcile as weakest statements")
    func legacyPremiumFold() {
        let cloud = UserChoiceFakeCloud()
        // A device on the OLD build wrote the legacy channel directly.
        cloud.storage[UserChoiceCloudSync.legacyMarkedKey] = ["feedA"]
        cloud.storage[UserChoiceCloudSync.legacyBlockedRemovedKey] = ["feedB"]

        let b = device(cloud, now: 2000)
        defer { cleanup(b.suite) }
        b.defaults.set(["feedB"], forKey: AppStorageKeys.blockedFeedKeys)
        b.sync.reconcile()
        // The marking arrives; the legacy removal does NOT delete B's t=0
        // stock (equal stamps, different values = honest tie, keep local).
        #expect(b.defaults.stringArray(forKey: AppStorageKeys.premiumMarkedFeeds) == ["feedA"])
        #expect(b.defaults.stringArray(forKey: AppStorageKeys.blockedFeedKeys) == ["feedB"])

        // A REAL later un-mark on the new build beats the legacy statement.
        b.sync.notePremiumMark("feedA", marked: false)
        let blob = cloud.storage[UserChoiceCloudSync.blobKey] as? [String: Any]
        let entry = UserChoiceEntry.from(plist: blob?[UserChoiceCatalog.premiumMarkPrefix + "feedA"])
        #expect(entry?.value == nil && (entry?.t ?? 0) > 0)
    }

    @Test("Continue-hidden markers travel; un-hide travels as tombstone")
    func hiddenMarkersTravel() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        let b = device(cloud, now: 2000)
        defer { cleanup(a.suite); cleanup(b.suite) }

        a.defaults.set(["book1": 555.0], forKey: AppStorageKeys.continueHiddenMarkers)
        a.sync.noteHidden(id: "book1", marker: 555.0)
        b.sync.reconcile()
        #expect(ContinueHiddenStore.markers(defaults: b.defaults)["book1"] == 555.0)

        b.defaults.set([:], forKey: AppStorageKeys.continueHiddenMarkers)
        b.sync.noteHidden(id: "book1", marker: nil)
        a.sync.reconcile()
        #expect(ContinueHiddenStore.markers(defaults: a.defaults)["book1"] == nil)
    }

    @Test("Per-title tempo and per-show settings travel as dynamic scalars")
    func dynamicScalarsTravel() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        let b = device(cloud, now: 2000)
        defer { cleanup(a.suite); cleanup(b.suite) }

        a.defaults.set(1.25, forKey: AppStorageKeys.playbackRate("bookX"))
        a.sync.noteScalar(key: AppStorageKeys.playbackRate("bookX"), value: 1.25)
        a.defaults.set("latest", forKey: AppStorageKeys.podcastInboxMode("feed:one"))
        a.sync.noteScalar(key: AppStorageKeys.podcastInboxMode("feed:one"), value: "latest")

        b.sync.reconcile()
        #expect(b.defaults.double(forKey: AppStorageKeys.playbackRate("bookX")) == 1.25)
        #expect(b.defaults.string(forKey: AppStorageKeys.podcastInboxMode("feed:one")) == "latest")
    }

    @Test("Budget: a realistic full family stays far below the KVS budget")
    func budgetMeasured() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        defer { cleanup(a.suite) }

        // 50 favorites, 500 per-title rates (the cap), 3×50 per-show
        // settings, 8 searches, 20 hidden markers, all scalars. Seeded as
        // STOCK and pushed by ONE reconcile (a note per entry would copy the
        // growing blob 600×, which is not the production shape and starved
        // the parallel wall-clock suites).
        var favorites: [RadioStation] = []
        for i in 0..<50 {
            let s = RadioStation(id: "radio:rb:station-\(UUID().uuidString)",
                                 name: "Station Number \(i) With A Name",
                                 streamURL: "https://example.org/stream/\(i)")
            favorites.append(s)
        }
        RadioStore.replaceFavorites(favorites, defaults: a.defaults)
        for i in 0..<500 {
            a.defaults.set(1.25, forKey: AppStorageKeys.playbackRate("abs-item-\(i)-longer-id"))
        }
        for i in 0..<50 {
            let show = "feed:https-example-org-show-\(i)"
            a.defaults.set("latest", forKey: AppStorageKeys.podcastInboxMode(show))
            a.defaults.set(false, forKey: AppStorageKeys.podcastNotify(show))
            a.defaults.set(25, forKey: AppStorageKeys.podcastEpisodeLimit(show))
        }
        a.defaults.set((0..<8).map { "suchbegriff nummer \($0)" }, forKey: RecentSearches.storageKey)
        a.defaults.set(Dictionary(uniqueKeysWithValues: (0..<20).map { ("abs-book-\($0)", 12345.0) }),
                       forKey: AppStorageKeys.continueHiddenMarkers)
        for key in UserChoiceCatalog.travelingScalars {
            a.defaults.set("some-choice-value", forKey: key)
        }
        a.sync.reconcile()

        let bytes = a.sync.blobBytes()
        // Budget line for the report; hard ceiling far under 1 MB.
        print("CHOICE budget blob bytes: \(bytes)")
        #expect(bytes > 0 && bytes < 120_000, "measured blob: \(bytes) bytes")
    }

    @Test("Rate cap: the 501st rate evicts the oldest, never the newest")
    func rateCapPrunes() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        defer { cleanup(a.suite) }
        // Stock + hand-written stamps (distinct event times), one reconcile.
        // Not 501 notes (each copies the growing blob; not the production
        // shape).
        var stamps: [String: Double] = [:]
        for i in 0...UserChoiceCatalog.playbackRateCap {
            a.defaults.set(1.5, forKey: AppStorageKeys.playbackRate("item-\(i)"))
            stamps[AppStorageKeys.playbackRate("item-\(i)")] = 5000 + Double(i)
        }
        a.defaults.set(stamps, forKey: UserChoiceCloudSync.stampsKey)
        a.sync.reconcile()
        let blob = cloud.storage[UserChoiceCloudSync.blobKey] as? [String: Any] ?? [:]
        let rates = blob.keys.filter { $0.hasPrefix("playbackRate.") }
        #expect(rates.count == UserChoiceCatalog.playbackRateCap)
        #expect(!rates.contains("playbackRate.item-0"))
        #expect(rates.contains("playbackRate.item-\(UserChoiceCatalog.playbackRateCap)"))
    }

    @Test("The cap holds on the NOTE path too — no reconcile in between")
    func rateCapPrunesOnNote() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        defer { cleanup(a.suite) }
        var stamps: [String: Double] = [:]
        for i in 0..<UserChoiceCatalog.playbackRateCap {
            a.defaults.set(1.5, forKey: AppStorageKeys.playbackRate("item-\(i)"))
            // Below the injected clock (starts at 1000). The fresh note must
            // be the NEWEST entry, or the cap would evict it instead.
            stamps[AppStorageKeys.playbackRate("item-\(i)")] = 100 + Double(i)
        }
        a.defaults.set(stamps, forKey: UserChoiceCloudSync.stampsKey)
        a.sync.reconcile()   // blob at the cap
        // The 501st rate arrives as a plain user NOTE (foregrounded device,
        // no reconcile). The oldest must fall, the newest must land.
        a.sync.noteScalar(key: AppStorageKeys.playbackRate("item-fresh"), value: 1.5)
        let blob = cloud.storage[UserChoiceCloudSync.blobKey] as? [String: Any] ?? [:]
        let rates = blob.keys.filter { $0.hasPrefix("playbackRate.") }
        #expect(rates.count == UserChoiceCatalog.playbackRateCap)
        #expect(rates.contains("playbackRate.item-fresh"))
        #expect(!rates.contains("playbackRate.item-0"))
    }
}

/// The birth gate: every persisted key of the key-bearing files carries a
/// declared sync class, and the travelling set matches the DECIDED member
/// list exactly. A new key without a class, or a silent class change, turns
/// the suite red.
struct UserChoiceGateTests {

    private func sourceText(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func captures(_ pattern: String, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    @Test("Every stored key in the key-bearing files is classified")
    func everyKeyIsClassified() throws {
        let files = ["Sources/Models/AppStorageKeys.swift",
                     "Sources/Models/RadioModels.swift",
                     "Sources/Models/RecentSearches.swift"]
        var found: Set<String> = []
        var foundPrefixes: Set<String> = []
        for file in files {
            let text = try sourceText(file)
            found.formUnion(try captures(#"static let [A-Za-z]+ *= *"([^"\\]+)""#, in: text))
            foundPrefixes.formUnion(try captures(#""([A-Za-z]+\.)\\\("#, in: text))
        }
        let unclassified = found.filter { UserChoiceCatalog.statics[$0] == nil }
        #expect(unclassified.isEmpty, "keys without a declared sync class: \(unclassified.sorted())")
        let unclassifiedPrefixes = foundPrefixes.filter { UserChoiceCatalog.prefixes[$0] == nil }
        #expect(unclassifiedPrefixes.isEmpty,
                "dynamic key families without a class: \(unclassifiedPrefixes.sorted())")
    }

    @Test("The travelling set matches the decided member list exactly")
    func travelSetMatchesTheOrder() {
        let decidedScalars: Set<String> = [
            "librarySortOption", "librarySortAscending", "libraryFilterOption",
            "podcastSortOption", "podcastFilterOption", "musicSortOption",
            "radioGenreCountryCodes",
            "radioChosenCountryCode", "radioChosenCountryName",
            "radioRegionCountryCode", "radioRegionCountryName", "radioRegionState",
            "lastPlayedItemId",
        ]
        let decidedElementFamilies: Set<String> = [
            "radioFavorites", "recentSearches", "continueHiddenMarkers",
            "premiumMarkedFeeds", "blockedFeedKeys",
            // Server addresses that once worked (decided); credentials never.
            "knownServers",
        ]
        let decidedPrefixes: Set<String> = [
            "playbackRate.", "podcastInboxMode.", "podcastNotify.", "podcastEpisodeLimit.",
        ]
        let travelingStatics = Set(UserChoiceCatalog.statics.filter { $0.value == .travels }.keys)
        #expect(travelingStatics == decidedScalars.union(decidedElementFamilies))
        #expect(Set(UserChoiceCatalog.travelingScalars) == decidedScalars)
        let travelingPrefixes = Set(UserChoiceCatalog.prefixes.filter { $0.value == .travels }.keys)
        #expect(travelingPrefixes == decidedPrefixes)
        #expect(Set(UserChoiceCatalog.travelingPrefixes) == decidedPrefixes)
    }
}
#endif
