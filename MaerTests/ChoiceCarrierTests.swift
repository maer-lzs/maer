// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A carrier that only remembers, so the runner's use of the seam is
/// visible without a store: what it stored, what it read, when it asked
/// the far side to flush, and the hook it left for changes.
@MainActor
private final class FakeChoiceCarrier: ChoiceCarrier {
    let name = "fake"
    var blob: [String: Any] = [:]
    var stored: [[String: Any]] = []
    var legacy: [String: [String]] = [:]
    var flushes = 0
    var onChange: (@MainActor () -> Void)?

    func loadBlob() -> [String: Any] { blob }
    func storeBlob(_ blob: [String: Any]) { self.blob = blob; stored.append(blob) }
    func legacyList(forKey key: String) -> [String]? { legacy[key] }
    func flush() { flushes += 1 }
    func start(onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
    func stop() {}
}

/// The seam behind the travelling choices: the key-value carrier, the
/// factory, and the fence that keeps every store primitive out of the
/// runner.
struct ChoiceCarrierTests {

    @Test("der Schluessel-Traeger traegt den Blob hin und zurueck") @MainActor
    func keyValueCarrierRoundTrip() {
        let store = InMemoryCloudStore()
        let carrier = KeyValueChoiceCarrier(store: store)
        #expect(carrier.loadBlob().isEmpty)
        carrier.storeBlob(["sort.books": ["t": 5.0, "v": "title"]])
        let entry = carrier.loadBlob()["sort.books"] as? [String: Any]
        #expect(entry?["t"] as? Double == 5.0)
        #expect(entry?["v"] as? String == "title")
        // The key lives with the carrier; the runner keeps only its name.
        #expect(store.dictionary(forKey: KeyValueChoiceCarrier.blobKey)?.count == 1)
        #expect(UserChoiceCloudSync.blobKey == "userChoices")
        #expect(carrier.name == "kvs")
    }

    @Test("der Schluessel-Traeger liest die alten Listen, eine fremde Frage bleibt nil") @MainActor
    func legacyListsComeFromTheStore() {
        let store = InMemoryCloudStore()
        let carrier = KeyValueChoiceCarrier(store: store)
        store.set(["feedA", "feedB"], forKey: UserChoiceCloudSync.legacyMarkedKey)
        #expect(carrier.legacyList(forKey: UserChoiceCloudSync.legacyMarkedKey) == ["feedA", "feedB"])
        #expect(carrier.legacyList(forKey: UserChoiceCloudSync.legacyBlockedKey) == nil)
    }

    @Test("ein Beobachter, nie zwei") @MainActor
    func oneObserverOnly() {
        let carrier = KeyValueChoiceCarrier(store: InMemoryCloudStore())
        carrier.start {}
        carrier.start {}
        #expect(carrier.observerRegistrations == 1)
    }

    @Test("die Fabrik stellt die Wahlen auf den Dienst, sobald ein Zugang da ist, sonst auf den Schluessel") @MainActor
    func factoryChoosesByAccess() {
        #expect(ChoiceCarriers.make(access: nil) is KeyValueChoiceCarrier)
        let access = MaerSyncAccess(baseURL: URL(string: "https://sync.example.test")!, token: "a-token")
        #expect(ChoiceCarriers.make(access: access) is MaerSyncChoiceCarrier)
    }

    /// The blob as typed entries, so two blobs compare by what they say.
    private func entries(_ blob: [String: Any]) -> [String: UserChoiceEntry] {
        var out: [String: UserChoiceEntry] = [:]
        for (key, raw) in blob { if let entry = UserChoiceEntry.from(plist: raw) { out[key] = entry } }
        return out
    }

    private var sample: [String: Any] {
        ["sort.books": UserChoiceEntry(value: .string("title"), t: 1000).plist,
         "radioFavorite.x": UserChoiceEntry(value: .data(Data([1, 2, 3])), t: 2000).plist,
         "playbackRate.y": UserChoiceEntry(value: .double(1.25), t: 2500).plist,
         "cleared": UserChoiceEntry(value: nil, t: 3000).plist]
    }

    @Test("der Dienst-Traeger: der Blob reist als EIN Dokument, eine fremde Fassung weckt den Laeufer") @MainActor
    func serviceCarrierWritesOneWholeDocument() async throws {
        let name = "choice-svc-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = MaerSyncCarrierTests.FakeTransport()
        let access = MaerSyncAccess(baseURL: URL(string: "https://sync.example.test")!, token: "a-token")
        let session = MaerSyncSession(transport: transport, announcer: MaerSyncCarrierTests.FakeAnnouncer(),
                                      access: { access }, deviceId: { "dev-a" }, defaults: defaults)
        let carrier = MaerSyncChoiceCarrier(session: session)
        var woken = 0
        carrier.start { woken += 1 }
        #expect(carrier.legacyList(forKey: UserChoiceCloudSync.legacyMarkedKey) == nil,
                "the old lists were only ever in the key-value store")

        carrier.storeBlob(sample)
        await session.refresh(by: "witness")
        let writes = transport.writes.filter { $0.kind == MaerSyncSession.choicesKind }
        #expect(writes.map(\.scope) == [""], "one whole document, no per-device scope")
        #expect(writes.first?.declared == true, "the blob may shrink (rate cap, aged tombstones), so the shrink is declared")
        let key = MaerSyncCarrierTests.FakeTransport.key(MaerSyncSession.choicesKind, "")
        let stored = try #require(transport.documents[key])
        #expect(entries(MaerSyncChoiceWire.decode(stored.body) ?? [:]) == entries(sample))
        #expect(entries(carrier.loadBlob()) == entries(sample))

        // Another device writes a different blob; the version moves, the
        // next round takes it and wakes the runner to re-merge.
        let other: [String: Any] = ["sort.books": UserChoiceEntry(value: .string("author"), t: 5000).plist]
        transport.foreignWrite(kind: MaerSyncSession.choicesKind, scope: "",
                               body: try MaerSyncChoiceWire.encode(other))
        await session.refresh(by: "tick")
        #expect(entries(carrier.loadBlob()) == entries(other), "the far side is now the other device's blob")
        #expect(woken >= 1)
        // The playlists channel and the per-device families are untouched.
        #expect(session.playlistsBody == nil)
        #expect(session.claims.isEmpty)
    }

    @Test("der Draht traegt jeden Werttyp exakt hin und zurueck; Unlesbares ist kein Blob, ein unbekannter Tag kein Grabstein") @MainActor
    func theServiceWireRoundTrips() throws {
        let every: [String: Any] = [
            "s": UserChoiceEntry(value: .string("x"), t: 1).plist,
            "b": UserChoiceEntry(value: .bool(true), t: 2).plist,
            "i": UserChoiceEntry(value: .int(1), t: 3).plist,
            "d": UserChoiceEntry(value: .double(1), t: 4).plist,
            "l": UserChoiceEntry(value: .stringList(["a", "b"]), t: 5).plist,
            "x": UserChoiceEntry(value: .data(Data([0, 255])), t: 6).plist,
            "gone": UserChoiceEntry(value: nil, t: 7).plist,
        ]
        let data = try MaerSyncChoiceWire.encode(every)
        let back = try #require(MaerSyncChoiceWire.decode(data))
        #expect(entries(back) == entries(every))
        // int stays int and double stays double, which the merge's equal-value guard relies on.
        #expect(entries(back)["i"]?.value == .int(1))
        #expect(entries(back)["d"]?.value == .double(1))
        #expect(entries(back)["b"]?.value == .bool(true))
        #expect(entries(back)["gone"]?.value == nil && entries(back)["gone"]?.t == 7)
        // The same blob gives the same bytes, so a needless write is a byte-for-byte match.
        #expect(try MaerSyncChoiceWire.encode(every) == data)
        #expect(MaerSyncChoiceWire.decode(Data("nonsense".utf8)) == nil)
        // A tag this build does not know is skipped, never read as a cleared key.
        let unknown = Data(#"{"entries":{"k":{"t":1,"v":{"zz":1}},"ok":{"t":2,"v":{"s":"y"}}}}"#.utf8)
        let read = try #require(MaerSyncChoiceWire.decode(unknown))
        #expect(entries(read)["k"] == nil)
        #expect(entries(read)["ok"]?.value == .string("y"))
    }

    @Test("der Laeufer notiert und uebernimmt ueber einen eingereichten Traeger") @MainActor
    func runnerRunsOverTheCarrier() throws {
        let suite = "choice-carrier-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let carrier = FakeChoiceCarrier()
        let sync = UserChoiceCloudSync(defaults: defaults, carrier: carrier,
                                       syncEnabled: { true }, now: { 1000 })
        sync.start()
        #expect(carrier.onChange != nil, "start hands the carrier its wake-up")

        // A note goes out through the carrier, as the whole blob.
        sync.noteScalar(key: "sort.books", value: "title")
        #expect(carrier.stored.count == 1)
        let noted = carrier.blob["sort.books"] as? [String: Any]
        #expect(noted?["t"] as? Double == 1000)

        // A statement the far side wrote is read through the carrier and
        // adopted when the carrier says the far side moved.
        carrier.blob["someForeignKey"] = UserChoiceEntry(value: .bool(true), t: 2000).plist
        carrier.onChange?()
        #expect(defaults.object(forKey: "someForeignKey") as? Bool == true)
    }

    /// The seam's fence: the runner holds every rule and no store
    /// primitive. What it may still say is the protocol's name in its
    /// `init`, which turns a witness's dictionary fake into the key-value
    /// carrier.
    @Test("der Zaun: der Laeufer nennt kein Speicher-Primitiv") @MainActor
    func onlyTheCarrierNamesTheStore() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let runner = try String(contentsOf: root.appendingPathComponent("Sources/Networking/UserChoiceCloudSync.swift"),
                                encoding: .utf8)
        let code = runner.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        for word in ["NSUbiquitousKeyValueStore", "didChangeExternallyNotification", "CloudQuotaWatch",
                     "cloud.dictionary(", "cloud.set(", "cloud.array(", "cloud.synchronize(", "\"userChoices\""] {
            #expect(!code.contains(word), "the runner names the store: \(word)")
        }
        // The detector sees a real primitive.
        #expect("let blob = cloud.dictionary(forKey: k)".contains("cloud.dictionary("))
    }
}
#endif
