// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Synchronization
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

    @Test("TF-1b: der Abgleich zaehlt Abos hier, im Dokument, geloescht und im Dokument, aber hier nicht gehalten")
    func subscriptionsCounted() {
        let prefix = UserChoiceCatalog.subscriptionPrefix
        let blob: [String: Any] = [
            prefix + "a": entry(.string("https://a.example/feed"), 1).plist,
            prefix + "b": entry(.string("https://b.example/feed?token=x"), 2).plist,
            prefix + "c": entry(nil, 3).plist,
            "playbackRate.x": entry(.double(1.5), 4).plist,
        ]
        let held: [String: UserChoiceEntry] = [prefix + "a": entry(.string("https://a.example/feed"), 1)]
        #expect(UserChoiceMerge.subscriptionCount(local: ["a"], localEntries: held, blob: blob)
                == .init(local: 1, document: 2, removed: 1, unheld: 1, adopt: 1), "b travels, is not followed, and is offered")
        #expect(UserChoiceMerge.subscriptionCount(local: ["a", "b", "z"], localEntries: held, blob: blob)
                == .init(local: 3, document: 2, removed: 1, unheld: 0), "held here and not in the document is not unheld")
        #expect(UserChoiceMerge.subscriptionCount(local: nil, localEntries: [:], blob: blob)
                == .init(local: nil, document: 2, removed: 1, unheld: nil), "an unloaded store is unknown, not empty")
        #expect(UserChoiceMerge.subscriptionCount(local: [], localEntries: [:], blob: [:])
                == .init(local: 0, document: 0, removed: 0, unheld: 0))
        // A newer removal recorded here keeps b away: pushed, never offered.
        let leftHere = held.merging([prefix + "b": entry(nil, 9)]) { $1 }
        #expect(UserChoiceMerge.subscriptionCount(local: ["a"], localEntries: leftHere, blob: blob)
                == .init(local: 1, document: 2, removed: 1, unheld: 1, push: 1))
    }

    @Test("TF-1b: der Abgleich sagt die Zahlen, die stille Feed-Runde sagt sich")
    func theCountsAreSaid() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func flat(_ relative: String) throws -> String {
            let text = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            return SyncContractFenceTests.stripped(text).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let choices = try flat("Sources/Networking/UserChoiceCloudSync.swift")
        #expect(choices.contains("let count = UserChoiceMerge.subscriptionCount(local: localSubscriptions().map { Set($0.keys) }, localEntries: localEntries, blob: blob)"))
        #expect(choices.contains("Logger.library.notice(\"CHOICE subscriptions local="), "the reconcile says the counts")
        #expect(choices.contains("Logger.library.notice(\"CHOICE subscriptions offered="), "the hand-over says whether anyone takes it")
        let store = try flat("Sources/Providers/PodcastSubscriptions.swift")
        #expect(store.contains("SUBSCRIBE cloud adoption skipped, already fetching"), "no skip of an offered feed is silent")
        // The episodes of one show, counted where stock and feed meet.
        #expect(store.contains("Logger.rss.notice(\"PODCAST refresh show=\\(show.id, privacy: .private(mask: .hash)) stock="),
                "each refresh says stock, feed and union")
        #expect(store.contains("Logger.rss.notice(\"PODCAST full history\\(browsed ? \" browsed\" : \"\", privacy: .public) show=\\(show.id, privacy: .private(mask: .hash)) stock="),
                "the history load says the same counts, and whether the show is only browsed")
        let feed = try flat("Sources/Networking/FeedAuthSync.swift")
        #expect(feed.contains("Logger.library.notice(\"FEEDAUTH unchanged, nothing put up envelope="),
                "a round that holds back says so")
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

    @Test("Recents merge: a ring without times keeps its local order, a dated foreign station goes first")
    func recentsMergeKeepsLocalOrderOnTies() {
        let a = RadioStation(id: "radio:rb:a", name: "A", streamURL: "http://a")
        let b = RadioStation(id: "radio:rb:b", name: "B", streamURL: "http://b")
        let c = RadioStation(id: "radio:rb:c", name: "C", streamURL: "http://c")
        let foreign = RadioStation(id: "radio:rb:f", name: "F", streamURL: "http://f")
        let merged = UserChoiceMerge.mergedRecents(
            elements: [(a, 0), (b, 0), (c, 0), (foreign, 900)].map { (station: $0.0, t: $0.1) },
            localOrder: ["radio:rb:c", "radio:rb:a", "radio:rb:b"], cap: 8)
        #expect(merged.map(\.station.id) == ["radio:rb:f", "radio:rb:c", "radio:rb:a", "radio:rb:b"],
                "the id decides only after time and local order")
        // Stations this device never held tie by id, and the cap still cuts.
        let unknown = UserChoiceMerge.mergedRecents(
            elements: [(b, 0), (a, 0), (c, 0)].map { (station: $0.0, t: $0.1) }, localOrder: [], cap: 2)
        #expect(unknown.map(\.station.id) == ["radio:rb:a", "radio:rb:b"])
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
        // Newest two survive (t=300 pair, tie-broken by key). `k1` and `k3` drop.
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

    @Test("TF-5: Sortierung und Filter je Sendung reisen zum zweiten Geraet, ein Loeschen als Grabstein")
    func showSortAndFilterTravel() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        let b = device(cloud, now: 2000)
        defer { cleanup(a.suite); cleanup(b.suite) }
        let sort = PodcastShowPreferences.sortKey(showId: "feed:tf5")
        let filter = PodcastShowPreferences.filterKey(showId: "feed:tf5")
        #expect(b.defaults.object(forKey: sort) == nil && b.defaults.object(forKey: filter) == nil,
                "B holds nothing before, or the case measures nothing")

        // A chooses oldest first and only unplayed, two gestures, the way the page stores.
        let chosen = PodcastShowPreferences(newestFirst: false, unplayedOnly: true)
        for choice in PodcastShowPreferences.allChoices {
            chosen.store(choice, showId: "feed:tf5", mode: .subscribed, defaults: a.defaults,
                         note: { value, key in a.sync.noteScalar(key: key, value: value) })
        }
        b.sync.reconcile()
        #expect(b.defaults.object(forKey: sort) as? Bool == false, "the sort arrives")
        #expect(b.defaults.object(forKey: filter) as? Bool == true, "the filter arrives")
        #expect(PodcastShowPreferences.load(showId: "feed:tf5", mode: .subscribed, defaults: b.defaults) == chosen,
                "B's page opens as A left it")

        a.defaults.removeObject(forKey: filter)
        a.sync.noteScalar(key: filter, value: nil)
        b.sync.reconcile()
        #expect(b.defaults.object(forKey: filter) == nil, "a removal travels as a tombstone")
        #expect(b.defaults.object(forKey: sort) as? Bool == false, "and takes nothing else with it")

        // The stock case, the one on the devices today: a sort stored by an
        // older build, never said to anyone. Only the reconcile can carry
        // it, and it carries exactly the travelling families.
        let oldSort = PodcastShowPreferences.sortKey(showId: "feed:tf5-old")
        a.defaults.set(false, forKey: oldSort)
        a.sync.reconcile()
        b.sync.reconcile()
        #expect(b.defaults.object(forKey: oldSort) as? Bool == false, "a sort from before this build arrives too")
    }

    /// A source switch chosen on A arrives on B and takes the one door of
    /// the sources, as a switch flipped on B does; a choice that is no
    /// source switch does not.
    @Test("ein uebernommener Quellen-Schalter wirkt wie ein hier gestellter, eine andere Wahl nicht")
    func anAdoptedSourceSwitchTakesTheSourceDoor() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        let b = device(cloud, now: 2000)
        defer { cleanup(a.suite); cleanup(b.suite) }
        final class Doors { var taken = 0 }
        let doors = Doors()
        b.sync.sourcesAdopted = { doors.taken += 1 }

        a.defaults.set(true, forKey: AppStorageKeys.subsonicEnabled)
        a.sync.noteScalar(key: AppStorageKeys.subsonicEnabled, value: true)
        b.sync.reconcile()
        #expect(b.defaults.object(forKey: AppStorageKeys.subsonicEnabled) as? Bool == true, "the precondition: the switch arrived")
        #expect(doors.taken == 1, "the adopted switch left the clients as they were")

        a.sync.noteScalar(key: "musicSortOption", value: "nameZA")
        b.sync.reconcile()
        #expect(b.defaults.object(forKey: "musicSortOption") as? String == "nameZA", "the precondition: the sort arrived")
        #expect(doors.taken == 1, "a choice that is no source switch took the source door")

        let notTravelling = UserChoiceCatalog.sourceSwitches.filter { UserChoiceCatalog.statics[$0] != .travels }
        #expect(notTravelling.isEmpty, "a source switch that does not travel names nothing: \(notTravelling)")
    }

    /// Plan A: what the adoption announces is what an open show page and its
    /// sheet ask the rule with, and reading again gives B what A chose.
    @Test("Eine Uebernahme meldet die Werte der Sendung so, dass die offene Seite sie nachliest, und nur fuer diese Sendung")
    func anAdoptionTellsTheOpenShowPage() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        let b = device(cloud, now: 2000)
        defer { cleanup(a.suite); cleanup(b.suite) }
        let show = "feed:adopt-\(UUID().uuidString)"
        let heard = Mutex<[[String]]>([])
        let token = NotificationCenter.default.addObserver(forName: .userChoicesAdopted, object: nil, queue: nil) { note in
            let keys = PodcastShowPreferences.adoptedKeys(note.userInfo)
            heard.withLock { $0.append(keys) }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        // A chooses oldest first and a speed for the show, the way page and sheet store.
        let chosen = PodcastShowPreferences(newestFirst: false, unplayedOnly: false)
        chosen.store(\.newestFirst, showId: show, mode: .subscribed, defaults: a.defaults,
                     note: { value, key in a.sync.noteScalar(key: key, value: value) })
        a.defaults.set(Float(1.5), forKey: AppStorageKeys.podcastShowRate(show))
        a.sync.noteScalar(key: AppStorageKeys.podcastShowRate(show), value: 1.5)
        #expect(PodcastShowPreferences.load(showId: show, mode: .subscribed, defaults: b.defaults) == .default,
                "B's open page shows the default before, or the case measures nothing")

        b.sync.reconcile()
        let announced = heard.withLock { $0.flatMap { $0 } }
        #expect(PodcastShowPreferences.adoptionTouches(announced, showId: show), "I1: the open page is told")
        #expect(!PodcastShowPreferences.adoptionTouches(announced, showId: show + "-other"), "I3: another show is not")
        #expect(PodcastShowPreferences.load(showId: show, mode: .subscribed, defaults: b.defaults) == chosen,
                "reading again shows what A chose")
        #expect((b.defaults.object(forKey: AppStorageKeys.podcastShowRate(show)) as? NSNumber)?.floatValue == 1.5,
                "and the sheet's speed")
    }

    /// The book cleanup removes a travelling key without telling the sync.
    /// Its stamp stays, and the entry derived from it is a tombstone with
    /// the stamp of the value it came from. That equal stamp is why the
    /// removal does not travel: A's tombstone is not newer than the cloud's
    /// value, so A writes nothing. Behind it stands a second guard (a held
    /// value against an equal-stamp tombstone is written back), which a
    /// neighbour witness holds; this one holds that A writes nothing at all,
    /// or the two devices would trade the key on every round.
    @Test("Ein weggeraeumter Schluessel reist nicht als Loeschung, weil sein Grabstein den Stempel des Werts traegt")
    func aCleanedKeyDoesNotTravelAsARemoval() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        let b = device(cloud, now: 2000)
        defer { cleanup(a.suite); cleanup(b.suite) }
        let book = "gone-book-\(UUID().uuidString)"
        let key = AppStorageKeys.playbackRate(book)

        // A sets a speed the way the player does, B takes it.
        a.defaults.set(Float(1.5), forKey: key)
        a.sync.noteScalar(key: key, value: 1.5)
        b.sync.reconcile()
        #expect((b.defaults.object(forKey: key) as? NSNumber)?.floatValue == 1.5, "B holds the speed, or the case measures nothing")

        // The book is gone from A's library; the cleanup takes the key.
        AppStorageKeys.cleanupPerBookKeys(validItemIds: [], in: a.defaults)
        #expect(a.defaults.object(forKey: key) == nil, "the cleanup ran")
        a.sync.reconcile()
        let blob = cloud.storage[UserChoiceCloudSync.blobKey] as? [String: Any] ?? [:]
        #expect(UserChoiceEntry.from(plist: blob[key])?.value == .double(1.5),
                "A writes no tombstone: its stamp is the value's, not newer")
        b.sync.reconcile()
        #expect((b.defaults.object(forKey: key) as? NSNumber)?.floatValue == 1.5, "B keeps its speed")
        #expect(a.defaults.object(forKey: key) == nil, "and A does not take it back")
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

    /// Abos reisen: A abonniert, B (ohne Server) bekommt die Adresse zum
    /// Nachziehen; A bestellt ab, B bekommt den Grabstein. Ein Geraet MIT
    /// Podcast-Server wendet nichts an (der Server ist seine Wahrheit) und
    /// laesst den Stempel liegen, damit es spaeter noch angeboten wird.
    @Test("Abos reisen als Familie: abonnieren, abbestellen, Server-Geraet ignoriert")
    func subscriptionsTravel() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        let b = device(cloud, now: 2000)
        defer { cleanup(a.suite); cleanup(b.suite) }
        var adoptedOnB: [(feedURL: String, t: Double)] = []
        var removedOnB: [String] = []
        b.sync.subscriptionAdopter = { added, removed in adoptedOnB += added; removedOnB += removed }
        b.sync.localSubscriptions = { [:] }
        a.sync.localSubscriptions = { ["feedkey-a": "https://example.org/feed.xml"] }

        a.sync.noteSubscription(feedURL: "https://example.org/feed.xml", subscribed: true)
        b.sync.reconcile()
        #expect(adoptedOnB.map(\.feedURL) == ["https://example.org/feed.xml"])
        #expect(removedOnB.isEmpty)
        // Nothing but the address in the blob, under the family's key.
        let blob = cloud.storage[UserChoiceCloudSync.blobKey] as? [String: Any] ?? [:]
        let keys = blob.keys.filter { $0.hasPrefix(UserChoiceCatalog.subscriptionPrefix) }
        #expect(keys == [UserChoiceCatalog.subscriptionPrefix + PodcastSubscriptions.feedKey("https://example.org/feed.xml")])

        // B followed the feed (its store now lists it). A unsubscribes: the
        // tombstone reaches B.
        adoptedOnB = []
        b.sync.localSubscriptions = { [PodcastSubscriptions.feedKey("https://example.org/feed.xml"): "https://example.org/feed.xml"] }
        a.sync.localSubscriptions = { [:] }
        a.sync.noteSubscription(feedURL: "https://example.org/feed.xml", subscribed: false)
        b.sync.reconcile()
        #expect(removedOnB == [PodcastSubscriptions.feedKey("https://example.org/feed.xml")])
        #expect(adoptedOnB.isEmpty)

        // A device with a podcast server applies the family too (and hands
        // the change to its server in the next gpodder round). Its refusal
        // used to be where the family and the server drifted apart.
        let suiteC = "choice-test-\(UUID().uuidString)"
        let defaultsC = UserDefaults(suiteName: suiteC)!
        defer { cleanup(suiteC) }
        var clockC: Double = 3000
        let c = UserChoiceCloudSync(defaults: defaultsC, cloud: cloud, syncEnabled: { true },
                                    now: { clockC += 1; return clockC })
        var adoptedOnC = 0
        c.subscriptionAdopter = { added, removed in adoptedOnC += added.count + removed.count }
        c.localSubscriptions = { [:] }
        a.sync.noteSubscription(feedURL: "https://example.org/other.xml", subscribed: true)
        c.reconcile()
        // Two statements stand in the blob for C: A's new subscription and
        // A's tombstone of the first feed; both are handed to the adopter.
        #expect(adoptedOnC == 2, "a server device applies the family like any other")
        // And an unloaded store writes no tombstones: nil says nothing.
        b.sync.localSubscriptions = { nil }
        b.sync.reconcile()
        let after = cloud.storage[UserChoiceCloudSync.blobKey] as? [String: Any] ?? [:]
        let otherKey = UserChoiceCatalog.subscriptionPrefix + PodcastSubscriptions.feedKey("https://example.org/other.xml")
        #expect(UserChoiceEntry.from(plist: after[otherKey])?.value != nil, "B unloaded must not bury A's subscription")
    }

    /// "Not in the store" is not "unsubscribed": while B still follows the
    /// account's feeds (or one of them failed to load), a second reconcile
    /// must neither bury the missing ones for the whole account nor stamp
    /// them as held. Only the person's unsubscribe writes a tombstone.
    @Test("Unfertige Adoption: keine Grabsteine, keine Stempel, offene Abos werden erneut angeboten; nur Abbestellen begraebt")
    func unfinishedAdoptionWritesNoTombstones() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        let b = device(cloud, now: 2000)
        defer { cleanup(a.suite); cleanup(b.suite) }
        let feeds = (1...5).map { "https://example.org/feed\($0).xml" }
        let keys = feeds.map { PodcastSubscriptions.feedKey($0) }
        func cloudKey(_ i: Int) -> String { UserChoiceCatalog.subscriptionPrefix + keys[i] }
        a.sync.localSubscriptions = { Dictionary(uniqueKeysWithValues: zip(keys, feeds)) }
        for feed in feeds { a.sync.noteSubscription(feedURL: feed, subscribed: true) }

        var offeredOnB: [String] = []
        b.sync.subscriptionAdopter = { added, _ in offeredOnB += added.map(\.feedURL) }
        // B's store is loaded and empty, then follows 3 of 5 (2 still open:
        // slow, dead or waiting for a login).
        b.sync.localSubscriptions = { [:] }
        b.sync.reconcile()
        #expect(offeredOnB.count == 5)
        b.sync.localSubscriptions = { Dictionary(uniqueKeysWithValues: zip(keys.prefix(3), feeds.prefix(3))) }
        offeredOnB = []
        b.sync.reconcile()
        // (a) No tombstone in the blob, all five statements unchanged.
        let blob = cloud.storage[UserChoiceCloudSync.blobKey] as? [String: Any] ?? [:]
        for i in 0..<5 {
            #expect(UserChoiceEntry.from(plist: blob[cloudKey(i)])?.value == .string(feeds[i]),
                    "statement \(i) must survive an unfinished adoption")
        }
        // (b) The two open ones are offered again, and carry no stamp on B.
        #expect(Set(offeredOnB) == Set(feeds.suffix(2)), "open statements are re-offered")
        #expect(b.sync.localStamps()[cloudKey(3)] == nil && b.sync.localStamps()[cloudKey(4)] == nil,
                "no stamp before the feed is held")
        // Once held, nothing is offered any more.
        b.sync.localSubscriptions = { Dictionary(uniqueKeysWithValues: zip(keys, feeds)) }
        offeredOnB = []
        b.sync.reconcile()
        #expect(offeredOnB.isEmpty)
        // (c) The person's unsubscribe on B is the ONE way to a tombstone,
        // stamped with B's now, and A follows.
        var removedOnA: [String] = []
        a.sync.subscriptionAdopter = { _, removed in removedOnA += removed }
        b.sync.localSubscriptions = { Dictionary(uniqueKeysWithValues: zip(keys.prefix(4), feeds.prefix(4))) }
        b.sync.noteSubscription(feedURL: feeds[4], subscribed: false)
        let after = cloud.storage[UserChoiceCloudSync.blobKey] as? [String: Any] ?? [:]
        let tombstone = UserChoiceEntry.from(plist: after[cloudKey(4)])
        #expect(tombstone?.value == nil && (tombstone?.t ?? 0) > 2000, "tombstone from the unsubscribe, stamped now")
        a.sync.reconcile()
        #expect(removedOnA == [keys[4]])
    }

    /// A tombstone that carries the value's own stamp (an old install's
    /// derived loop) must not freeze the account: the device that holds the
    /// value writes it back, the other device adopts it. Stamp zero stays
    /// the honest tie (pre-family stock against a legacy removal).
    @Test("Unentschieden Wert gegen Grabstein mit gleichem Stempel: der gehaltene Wert reist, Stempel null bleibt liegen")
    func heldValueBeatsATombstoneWithTheSameStamp() {
        let value = UserChoiceEntry(value: .string("https://example.org/feed.xml"), t: 5000)
        let tombstone = UserChoiceEntry(value: nil, t: 5000)
        #expect(UserChoiceMerge.decide(local: value, cloud: tombstone) == .push(5000))
        // Rot-Proben: a NEWER tombstone still wins, and stamp zero ties.
        #expect(UserChoiceMerge.decide(local: value, cloud: UserChoiceEntry(value: nil, t: 6000)) == .adopt)
        #expect(UserChoiceMerge.decide(local: UserChoiceEntry(value: .bool(true), t: 0),
                                       cloud: UserChoiceEntry(value: nil, t: 0)) == .none)
        // The whole way: the blob holds the frozen tombstone, A holds the
        // value with the same stamp, B holds nothing.
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        let b = device(cloud, now: 2000)
        defer { cleanup(a.suite); cleanup(b.suite) }
        let feed = "https://example.org/frozen.xml"
        let key = UserChoiceCatalog.subscriptionPrefix + PodcastSubscriptions.feedKey(feed)
        cloud.storage[UserChoiceCloudSync.blobKey] = [key: UserChoiceEntry(value: nil, t: 5000).plist]
        a.defaults.set([key: 5000.0], forKey: UserChoiceCloudSync.stampsKey)
        a.sync.localSubscriptions = { [PodcastSubscriptions.feedKey(feed): feed] }
        a.sync.reconcile()
        let blob = cloud.storage[UserChoiceCloudSync.blobKey] as? [String: Any] ?? [:]
        #expect(UserChoiceEntry.from(plist: blob[key])?.value == .string(feed), "A writes the held value back")
        var offeredOnB: [String] = []
        b.sync.subscriptionAdopter = { added, _ in offeredOnB += added.map(\.feedURL) }
        b.sync.localSubscriptions = { [:] }
        b.sync.reconcile()
        #expect(offeredOnB == [feed], "B adopts the value that was frozen behind the tombstone")
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

    /// The last-heard stations travel: both devices see both, newest play
    /// first; a removal on one device is a tombstone and takes the station
    /// off the other, and it does not come back on the next reconcile.
    @Test("Radio-Verlaeufe reisen: beide sehen beide, Entfernen auf A folgt B")
    func recentStationsTravel() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        let b = device(cloud, now: 2000)
        defer { cleanup(a.suite); cleanup(b.suite) }

        let x = RadioStation(id: "radio:rb:x", name: "X", streamURL: "http://x")
        let y = RadioStation(id: "radio:rb:y", name: "Y", streamURL: "http://y")

        RadioStore.recordRecent(x, defaults: a.defaults)
        a.sync.noteRecentStation(x, removed: false)
        RadioStore.recordRecent(y, defaults: b.defaults)
        b.sync.noteRecentStation(y, removed: false)

        a.sync.reconcile()
        b.sync.reconcile()
        a.sync.reconcile()
        #expect(Set(RadioStore.recents(defaults: a.defaults).map(\.id)) == ["radio:rb:x", "radio:rb:y"])
        #expect(Set(RadioStore.recents(defaults: b.defaults).map(\.id)) == ["radio:rb:x", "radio:rb:y"])
        #expect(RadioStore.recents(defaults: b.defaults).first?.id == "radio:rb:y",
                "the newer play stands first")
        #expect(RadioStore.recentTimes(defaults: a.defaults)["radio:rb:y"] != nil,
                "the adopted station carries its play moment")

        RadioStore.removeRecent(id: "radio:rb:x", defaults: a.defaults)
        a.sync.noteRecentStation(x, removed: true)
        b.sync.reconcile()
        #expect(!RadioStore.recents(defaults: b.defaults).map(\.id).contains("radio:rb:x"))
        b.sync.reconcile()
        a.sync.reconcile()
        #expect(!RadioStore.recents(defaults: a.defaults).map(\.id).contains("radio:rb:x"),
                "the removed station came back")
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

    /// Sort and filter per show were written as `podcastSort.<id>` in a
    /// file the gate below did not read, so they stayed on the device with
    /// no decision behind it. This one reads the whole source tree: a key
    /// family built as `"name.\(id)"` anywhere carries a class, or it is
    /// named here as no key at all.
    @Test("TF-5: jede Schluessel-Familie im ganzen Quellbaum hat eine Klasse", .needsTheSources)
    func everyKeyFamilyInTheSourcesIsClassified() throws {
        let notKeys: [String: String] = [
            "gobackward.": "an SF Symbol name for the skip button, never stored",
            "goforward.": "an SF Symbol name for the skip button, never stored",
        ]
        let root = SourceTree.root.appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        try #require(files.count > 100, "the fence did not read the source tree")
        var families: Set<String> = []
        for file in files {
            let text = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            families.formUnion(try captures(#""([A-Za-z]+\.)\\\("#, in: text))
        }
        let unclassified = families.filter { UserChoiceCatalog.prefixes[$0] == nil && notKeys[$0] == nil }
        #expect(unclassified.isEmpty, "key families without a class: \(unclassified.sorted())")
        let stale = Set(notKeys.keys).subtracting(families)
        #expect(stale.isEmpty, "named as no key, but no longer in the sources: \(stale.sorted())")
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
            // Decided: one account is one person, so what
            // the person chose is identical on both devices. Only downloads
            // and device technique stay behind, each named where it stays.
            "skipInterval", "musicSkipInterval", "defaultPlaybackRate",
            "smartRewind", "autoPlayNextInSeries",
            "appearanceOverride", "bottomBarAccent",
            "audiobooksTabEnabled", "podcastsTabEnabled", "musicTabEnabled", "radioTabEnabled",
            "radioEnabled", "subsonicEnabled", "jellyfinEnabled", "rssEnabled",
            "pinchflatEnabled", "absPodcastsEnabled", "absAudiobooksEnabled",
            "gpodderEnabled", "gpodderSyncsPremiumFeeds",
            "homeRecommendations", "suggestionLanguages", "appleCatalogEnabled",
            "radioLogoChainEnabled", "musicArtistImagesOnline", "musicLyricsOnlineLookup",
            "musicHighResCovers", "librivoxRowsEnabled", "archivePopularEnabled",
            "jamendoRowEnabled", "freeClassicalEnabled", "netlabelsRowEnabled",
            "shellacRowsEnabled", "freeAudiobooksEnabled",
            "gutenbergSourceEnabled", "podcastIndexSourceEnabled", "feedArtworkSourceEnabled",
            "rowHomeDiscoverMusicVisible", "rowHomeRecentlyAddedVisible", "rowBooksRecentVisible",
            "jamendoRowVisible", "rowPodcastsRadioPlaysVisible", "rowPodcastsRecommendedVisible",
            "rowRadioCatalogVisible", "rowHomeDiscoverBooksVisible", "rowHomeRediscoverVisible",
            "rowBooksChartsVisible", "podcastsPinchflatInSubscriptions", "podcastsPremiumInSubscriptions",
            "coListenedHidden", "podcastAutoSaveOnPlay", "podcastSubscribeToServer",
            // The switch is the intent and travels; the iOS permission
            // stays with the device (ENTSCHIEDEN, question 1, 07.09.2026).
            "podcastNewEpisodeNotifications",
            // The value for all shows stands behind a per-show value that
            // travels, so it travels too. The episode limit is retired. The
            // direction of the automatic download is how the person listens
            // and travels.
            "podcastInboxModeAll", "podcastAutoDownloadDirectionAll",
            // How close to the end counts as played, for all shows and books
            // (decided 28.09.2026).
            "playedTailSeconds",
        ]
        let decidedElementFamilies: Set<String> = [
            "radioFavorites", "recentSearches", "continueHiddenMarkers",
            // The last-heard stations and their play moments (decided 05.09.).
            "radioRecents", "radioRecentTimes",
            "premiumMarkedFeeds", "blockedFeedKeys",
            // Server addresses that once worked (decided); credentials never.
            "knownServers",
            // The podcast subscriptions (decided): one statement per feed.
            "podcastSubscriptions",
            // Stations entered by hand and the chosen stream variant of a
            // station travel element by element, like the favourites.
            "radioManualStations", "radioVariantSelection",
        ]
        let decidedPrefixes: Set<String> = [
            "playbackRate.", "podcastInboxMode.", "podcastNotify.",
            // Decided: every per-show setting travels; the show rate was the
            // one device-class exception without a stated reason.
            "podcastShowRate.",
            // A sort is chosen, and "everything chosen travels"
            // holds for the show page as for the tab.
            "podcastSort.", "podcastFilter.",
            // The direction of the automatic download per show (27.09.2026).
            "podcastAutoDownloadDirection.",
            // "Counts as played" per show and per book (decided 28.09.2026).
            "playedTail.",
            // The free feed of a paid show travels like a subscription
            // attribute (decided 28.09.2026).
            "podcastFreeTwin.",
        ]
        let travelingStatics = Set(UserChoiceCatalog.statics.filter { $0.value == .travels }.keys)
        #expect(travelingStatics == decidedScalars.union(decidedElementFamilies))
        #expect(Set(UserChoiceCatalog.travelingScalars) == decidedScalars)
        let travelingPrefixes = Set(UserChoiceCatalog.prefixes.filter { $0.value == .travels }.keys)
        #expect(travelingPrefixes == decidedPrefixes)
        #expect(Set(UserChoiceCatalog.travelingPrefixes) == decidedPrefixes)
    }

    @Test("Was beim Geraet bleibt, bleibt mit Grund; der Sync-Schalter selbst reist nie")
    func whatStaysWithTheDeviceIsNamed() {
        let staying = Set(UserChoiceCatalog.statics.filter { $0.value == .device }.keys)
        // Each of these has its reason written at the entry: the switch
        // that decides travelling, the connection of THIS device, the car
        // it pairs with, a permission granted per device, a window state,
        // what is missing here, and the two lists that are not scalars yet.
        #expect(staying == [
            "podcastICloudSync", "warnCellularDownload",
            "driveModeCarRouteUID", "driveModeCarRouteName", "driveModeAutoStart",
            "lastSelectedTab",
            "podcastFeedsNeedingSignIn", "podcastFeedRefusals", "serverlessMode",
            "podcastFreeTwinSearched", "podcastFreeTwinDeclined", "podcastPaidTwin",
            "nextStepsDismissed", "foreignImportsDone",
            "sleepTimerLastMinutes",
            // Automatic downloads stay on the device that downloads
            // (decided 06.09.2026), for all shows as for each show: whether
            // they run and how many they keep (27.09.2026). The one value of
            // the builds before is only read.
            "podcastAutoDownloadModeAll", "podcastAutoDownloadSinceAll",
            "podcastAutoDownloadOnAll", "podcastAutoDownloadKeepAll",
        ])
        // The switch that decides whether anything travels can never
        // travel itself: one device would silence the other.
        #expect(UserChoiceCatalog.statics["podcastICloudSync"] == .device)
        #expect(!UserChoiceCatalog.travelingScalars.contains("podcastICloudSync"))
    }
}
#endif
