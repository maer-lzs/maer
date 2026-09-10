// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The claim's transport is a carrier; the rule is not. A carrier that
/// only records what it is told proves the runner talks to nothing else:
/// the own claim goes out through `write`, foreign claims come in through
/// `claims`, a delivery wakes the runner through `onChange`, an orphan
/// leaves through `remove`. And the key-value store is the one place that
/// names the store: the runner's file does not.
struct ClaimCarrierTests {
    @MainActor
    final class RecordingCarrier: ClaimCarrier {
        let name = "fake"
        let heartbeatSeconds: Double = 10
        var written: [PlaybackClaim] = []
        var held: [PlaybackClaim] = []
        var removed: [String] = []
        var deliver: (@MainActor () -> Void)?

        func write(_ claim: PlaybackClaim) { written.append(claim); held.removeAll { $0.deviceId == claim.deviceId }; held.append(claim) }
        func claims() -> [PlaybackClaim] { held }
        func remove(deviceId: String) { removed.append(deviceId); held.removeAll { $0.deviceId == deviceId } }
        func start(onChange: @escaping @MainActor () -> Void) { deliver = onChange }
    }

    @Test("der Laeufer schreibt, liest und hoert nur ueber den Traeger") @MainActor
    func runnerTalksOnlyToTheCarrier() {
        let carrier = RecordingCarrier()
        var clock: Double = 1_000_000
        let sync = PlaybackClaimSync(carrier: carrier, deviceId: { "dev-a" },
                                     deviceName: { "iPhone" }, now: { clock })
        var seen: [PlaybackClaim] = []
        sync.onForeignClaim = { seen.append($0) }

        sync.claim(itemId: "rss:f:ep", position: 12, playAt: clock)
        #expect(carrier.written.count == 1)
        #expect(carrier.written.first?.deviceId == "dev-a")
        #expect(carrier.written.first?.position == 12)

        // A foreign claim arrives through the carrier; the rule decides.
        carrier.held.append(PlaybackClaim(deviceId: "dev-b", itemId: "rss:f:ep", t: clock + 1_000,
                                          playAt: clock + 1_000))
        sync.poll()
        #expect(seen.map(\.deviceId) == ["dev-b"])
        #expect(sync.current?.deviceId == "dev-b")

        // A release is a write with the flag, never a removal.
        sync.release(itemId: "rss:f:ep", position: 20)
        #expect(carrier.written.last?.released == true)
        #expect(carrier.removed.isEmpty)

        // An orphan (a device gone for longer than the window) is removed
        // through the carrier, the own claim never.
        clock += (PlaybackClaimSync.orphanSeconds + 60) * 1000
        _ = sync.allClaims()
        #expect(carrier.removed == ["dev-b"])
        #expect(carrier.held.map(\.deviceId) == ["dev-a"])
    }

    @Test("der Zaun: nur der Schluessel-Traeger nennt den Speicher") @MainActor
    func onlyTheCarrierNamesTheStore() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let runner = try String(contentsOf: root.appendingPathComponent("Sources/Networking/PlaybackClaimSync.swift"), encoding: .utf8)
        let code = runner.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        for word in ["NSUbiquitousKeyValueStore", "UserChoiceCloudStore", "cloud.", "dictionaryRepresentation", "playbackClaim."] {
            #expect(!code.contains(word), "the runner names the store: \(word)")
        }
        // The key form lives with the carrier, the legacy key is still read.
        #expect(KeyValueClaimCarrier.key(for: "dev-a") == "playbackClaim.dev-a")
        #expect(KeyValueClaimCarrier.claimKey == "playbackClaim")
    }

    @Test("der Schluessel-Traeger liest je Geraet und den alten Einzelschluessel") @MainActor
    func keyValueCarrierReadsEveryDevice() {
        let store = InMemoryCloudStore()
        let carrier = KeyValueClaimCarrier(cloud: store)
        carrier.write(PlaybackClaim(deviceId: "dev-a", itemId: "x", t: 1))
        carrier.write(PlaybackClaim(deviceId: "dev-b", itemId: "y", t: 2))
        store.set(PlaybackClaim(deviceId: "dev-old", itemId: "z", t: 3).plist, forKey: KeyValueClaimCarrier.claimKey)
        #expect(Set(carrier.claims().map(\.deviceId)) == ["dev-a", "dev-b", "dev-old"])
        carrier.remove(deviceId: "dev-b")
        #expect(Set(carrier.claims().map(\.deviceId)) == ["dev-a", "dev-old"])
        #expect(carrier.name == "kvs")
    }
}
#endif
