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

    @Test("die Fabrik antwortet heute fuer beide Zugaenge den Schluessel-Traeger") @MainActor
    func factoryAnswersKeyValueForNow() {
        #expect(ChoiceCarriers.make(access: nil).name == "kvs")
        let access = MaerSyncAccess(baseURL: URL(string: "https://sync.example.test")!, token: "a-token")
        #expect(ChoiceCarriers.make(access: access).name == "kvs")
    }

    @Test("der Laeufer notiert und uebernimmt ueber einen eingereichten Traeger") @MainActor
    func runnerRunsOverTheCarrier() throws {
        let suite = "choice-carrier-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let carrier = FakeChoiceCarrier()
        let sync = UserChoiceCloudSync(defaults: defaults, carrier: carrier,
                                       syncEnabled: { true }, now: { 1000 },
                                       hasPodcastServer: { false })
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
