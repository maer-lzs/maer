// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The choices follow the account (decision of 03.10.2026, a new
/// beginning): at a switch the holder's choices rest on the shelf with
/// their stamps, the new account sees none of them and gets no removal of
/// theirs, and the way back brings every value back.
@MainActor
struct UserChoiceOwnerTests {
    /// One document per account: what the runner reads and writes is the
    /// one of the account signed in at that moment.
    private final class AccountCarrier: ChoiceCarrier {
        var name: String { "accounts" }
        let scope: () -> String?
        var pots: [String: [String: Any]] = [:]
        init(scope: @escaping () -> String?) { self.scope = scope }
        func loadBlob() -> [String: Any] { pots[scope() ?? "-"] ?? [:] }
        func storeBlob(_ blob: [String: Any]) { pots[scope() ?? "-"] = blob }
        func flush() {}
        func start(onChange: @escaping @MainActor () -> Void) {}
        func stop() {}
    }

    private struct Rig {
        let suite: String
        let defaults: UserDefaults
        let directory: URL
        var shelf: RestingShelf { RestingShelf(directory: directory) }
        func cleanup() {
            UserDefaults().removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func rig() -> Rig {
        let suite = "choice-owner-\(UUID().uuidString)"
        return Rig(suite: suite, defaults: UserDefaults(suiteName: suite)!,
                   directory: FileManager.default.temporaryDirectory
                       .appendingPathComponent("choice-owner-\(UUID().uuidString)", isDirectory: true))
    }

    /// Every key and value of a document, as one text to search for names.
    private func text(_ blob: [String: Any]?) -> String {
        (blob ?? [:]).map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
    }

    @Test("A's Wahlen ruhen samt Stempeln, B sieht keine davon und bekommt keinen Grabstein von A, der Rueckweg bringt jeden Wert zurueck")
    func theChoicesRestUnderTheirAccount() throws {
        let rig = rig()
        defer { rig.cleanup() }
        let defaults = rig.defaults
        var scope: String? = "account-a"
        var address: String? = "https://sync-a.example"
        var clock = 1000.0
        let carrier = AccountCarrier(scope: { scope })
        let sync = UserChoiceCloudSync(defaults: defaults, carrier: carrier, syncEnabled: { true },
                                       now: { clock += 1; return clock }, identity: { scope },
                                       serviceAddress: { address }, shelf: rig.shelf, idFormSettled: { true })
        sync.sourcesAdopted = {}

        // A's choices: a scalar, a rate of one book, a search, a cleared
        // search (a stamp without a value), a server.
        defaults.set("title", forKey: "librarySortOption")
        sync.noteScalar(key: "librarySortOption", value: "title")
        defaults.set(1.5, forKey: "playbackRate.krimi-buch")
        sync.noteScalar(key: "playbackRate.krimi-buch", value: 1.5)
        defaults.set(["moorleiche"], forKey: RecentSearches.storageKey)
        sync.noteSearch("moorleiche", removed: false)
        sync.noteSearch("geheimsache", removed: true)
        KnownServers.remember("https://music-a.example", service: .subsonic, defaults: defaults)
        KnownServers.remember("https://sync-a.example", service: .maerSync, defaults: defaults)
        sync.noteKnownServers()
        sync.reconcile()
        let ofA = try sync.restingChoices()
        #expect(text(carrier.pots["account-a"]).contains("geheimsache"), "A's document lacks A's removal")

        // The switch to B; the address of the service signed in comes
        // along by itself.
        scope = "account-b"
        address = "https://sync-b.example"
        sync.reconcile()
        #expect(defaults.object(forKey: "librarySortOption") == nil, "B sees A's sort")
        #expect(defaults.object(forKey: "playbackRate.krimi-buch") == nil, "B sees A's rate")
        #expect(RecentSearches.list(defaults: defaults).isEmpty, "B sees A's searches")
        #expect(KnownServers.all(defaults: defaults).map(\.url) == ["https://sync-b.example"],
                "B's register holds more than the service signed in")
        let ofB = text(carrier.pots["account-b"])
        for name in ["librarySortOption", "krimi-buch", "moorleiche", "geheimsache", "music-a", "sync-a"] {
            #expect(!ofB.contains(name), "\(name) of A went to B")
        }

        // B chooses for itself.
        defaults.set("author", forKey: "librarySortOption")
        sync.noteScalar(key: "librarySortOption", value: "author")
        sync.reconcile()

        scope = "account-a"
        address = "https://sync-a.example"
        sync.reconcile()
        let back = try sync.restingChoices()
        for (key, value) in ofA.values where key != KnownServers.storeKey && key != UserChoiceCloudSync.stampsKey {
            #expect(back.values[key] == value, "\(key) did not come back as it was")
        }
        #expect(Set(back.values.keys) == Set(ofA.values.keys))
        let stampData = try #require(ofA.values[UserChoiceCloudSync.stampsKey])
        let stampsOfA = try #require(PropertyListSerialization.propertyList(from: stampData, format: nil) as? [String: Double])
        let stampsBack = sync.localStamps()
        // The address signed in is remembered afresh; every other stamp is
        // the one A had.
        for (key, t) in stampsOfA where !key.hasPrefix(UserChoiceCatalog.knownServerPrefix) {
            #expect(stampsBack[key] == t, "the stamp of \(key) moved")
        }
        #expect(Set(KnownServers.all(defaults: defaults).map(\.url)) == ["https://music-a.example", "https://sync-a.example"])
        #expect(!text(carrier.pots["account-a"]).contains("author"), "B's choice went to A")
        #expect(text(carrier.pots["account-b"]).contains("author"))
    }

    @Test("ein offenes Ersetzen eines frueheren Laufs und ein drittes Konto: B's Ruhe traegt keine Wahl von A, A's bleiben bei A")
    func aThirdAccountAfterAnOpenReplacement() throws {
        let rig = rig()
        defer { rig.cleanup() }
        let defaults = rig.defaults
        let shelf = rig.shelf
        func plist(_ value: Any) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        }
        let restOfA = UserChoiceCloudSync.Resting(values: ["librarySortOption": try plist("title")])
        let restOfB = UserChoiceCloudSync.Resting(values: ["librarySortOption": try plist("author")])
        try shelf.lay(restOfA, of: "choices", owner: "account-a")
        try shelf.lay(restOfB, of: "choices", owner: "account-b")
        try shelf.setHolding(.init(owner: "account-b", replacing: true, from: "account-a", replacement: "open"), of: "choices")
        // The replacement of a run before never landed: A's choice is live.
        defaults.set("title", forKey: "librarySortOption")
        let carrier = AccountCarrier(scope: { "account-c" })
        var clock = 1000.0
        let sync = UserChoiceCloudSync(defaults: defaults, carrier: carrier, syncEnabled: { true },
                                       now: { clock += 1; return clock }, identity: { "account-c" },
                                       serviceAddress: { nil }, shelf: shelf, idFormSettled: { true })
        sync.sourcesAdopted = {}
        sync.reconcile()
        #expect(try shelf.rest(UserChoiceCloudSync.Resting.self, of: "choices", owner: "account-b") == restOfB,
                "A's choices were laid as B's")
        #expect(try shelf.rest(UserChoiceCloudSync.Resting.self, of: "choices", owner: "account-a") == restOfA)
        #expect(defaults.object(forKey: "librarySortOption") == nil, "C sees a choice of another account")
    }

    @Test("die Meldung der Uebernahme nennt auch die Schluessel, die beim Wechsel gingen")
    func theAnnouncementNamesTheKeysThatLeft() throws {
        let rig = rig()
        defer { rig.cleanup() }
        let defaults = rig.defaults
        var scope: String? = "account-a"
        let carrier = AccountCarrier(scope: { scope })
        var clock = 1000.0
        let sync = UserChoiceCloudSync(defaults: defaults, carrier: carrier, syncEnabled: { true },
                                       now: { clock += 1; return clock }, identity: { scope },
                                       serviceAddress: { nil }, shelf: rig.shelf, idFormSettled: { true })
        sync.sourcesAdopted = {}
        defaults.set(1.5, forKey: "playbackRate.krimi-buch")
        sync.noteScalar(key: "playbackRate.krimi-buch", value: 1.5)
        sync.reconcile()
        @MainActor final class Heard { var keys: [String] = [] }
        let heard = Heard()
        let token = NotificationCenter.default.addObserver(forName: .userChoicesAdopted, object: nil, queue: nil) { note in
            let keys = (note.userInfo?["keys"] as? [String]) ?? []
            MainActor.assumeIsolated { heard.keys += keys }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        scope = "account-b"
        sync.reconcile()
        #expect(defaults.object(forKey: "playbackRate.krimi-buch") == nil, "the precondition: A's rate left")
        #expect(heard.keys.contains("playbackRate.krimi-buch"), "the announcement left out a key that left")
    }

    @Test("kann die Ruhe nicht gelegt werden, bleiben die Wahlen und nichts geht zu B")
    func anUnlaidRestHoldsTheChoices() throws {
        let rig = rig()
        defer { rig.cleanup() }
        let defaults = rig.defaults
        var scope: String? = "account-a"
        var clock = 1000.0
        let carrier = AccountCarrier(scope: { scope })
        let sync = UserChoiceCloudSync(defaults: defaults, carrier: carrier, syncEnabled: { true },
                                       now: { clock += 1; return clock }, identity: { scope }, shelf: rig.shelf, idFormSettled: { true })
        sync.sourcesAdopted = {}
        defaults.set("title", forKey: "librarySortOption")
        sync.noteScalar(key: "librarySortOption", value: "title")
        sync.reconcile()

        // The shelf's place of the account is a folder: nothing can be laid.
        try FileManager.default.createDirectory(
            at: rig.directory.appendingPathComponent("choices").appendingPathComponent("account-a.json"),
            withIntermediateDirectories: true)
        scope = "account-b"
        sync.reconcile()
        sync.noteScalar(key: "librarySortOption", value: "title")
        #expect(defaults.string(forKey: "librarySortOption") == "title", "the choices left without a rest")
        #expect(carrier.pots["account-b"] == nil, "a held round or note carried A's choices to B")
    }
}
#endif
