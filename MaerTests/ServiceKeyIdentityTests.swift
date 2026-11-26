// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Testing
@testable import Maer

/// The identity of a Mär Sync account is named by the fingerprint of the
/// service's key. A pin this device holds but cannot read now makes it
/// unknown, never "by address": the families wait as for an unknown access
/// and nothing is kept under another name. A device whose access stood
/// without a pin (restored from a backup, or signed in before pins) takes
/// its state over to the fingerprint once the pin is held, instead of
/// leaving it behind under the address.
@MainActor
struct ServiceKeyIdentityTests {
    typealias FakeTransport = MaerSyncCarrierTests.FakeTransport
    typealias FakeAnnouncer = MaerSyncCarrierTests.FakeAnnouncer

    static let access = MaerSyncIdentityTests.accessA
    static let byKey = MaerSyncIdentityTests.identityA
    static let byAddress = MaerSyncIdentity(service: "address:\(access.baseURL.absoluteString)", owner: byKey.owner)

    final class Box {
        var access: MaerSyncAccess?
        var identity: MaerSyncIdentity?
        var unknown = false
    }

    private func session(_ box: Box, defaults: UserDefaults) -> MaerSyncSession {
        MaerSyncSession(transport: FakeTransport(), announcer: FakeAnnouncer(),
                        access: { box.access }, identity: { box.identity }, accessUnknown: { box.unknown },
                        deviceId: { "dev-a" }, defaults: defaults)
    }

    @Test("the identity: by the key's fingerprint when the pin reads, unknown when it cannot be read now, by address without a pin, none without an access")
    func theIdentity() {
        #expect(MaerSyncIdentity.read(access: Self.access, owner: "anna", pin: .held("fp-service")) == .known(Self.byKey))
        #expect(MaerSyncIdentity.read(access: Self.access, owner: "anna", pin: .unreadable) == .unknown)
        #expect(MaerSyncIdentity.read(access: Self.access, owner: "anna", pin: .damaged) == .unknown)
        #expect(MaerSyncIdentity.read(access: Self.access, owner: "anna", pin: ServiceKeyPin.PinRead.none) == .known(Self.byAddress))
        #expect(MaerSyncIdentity.read(access: nil, owner: "anna", pin: .unreadable) == ServiceKeyIdentityRead.none)
    }

    @Test("a pin there but not decodable is damaged, apart from one that cannot be read now")
    func damaged() {
        #expect(ServiceKeyPin.reading(.undecodable) == .damaged)
        #expect(ServiceKeyPin.reading(.unreadable) == .unreadable)
    }

    @Test("an access whose identity is unknown waits like an unknown access: no switch, nothing kept under another name; read again, the same account and its state")
    func unknownIdentityWaits() throws {
        let suite = "maer-pin-unknown-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rows = CarrierStandRows.matching(defaults)
        rows.set(Self.byKey.keyed(MaerSyncSession.mirrorKey), ["rss:a:1": [1, 1_000]])
        let box = Box()
        box.access = Self.access
        box.identity = nil
        box.unknown = true
        let session = session(box, defaults: defaults)
        #expect(session.accessUnknown, "a readable token with an unreadable pin counted as a known access")
        session.enqueue(upserts: ["rss:u:1": [5, 5_000]], removing: [], by: "witness")
        #expect(!rows.holds(Self.byAddress.keyed(MaerSyncSession.queueKey)), "the window wrote under the address")
        #expect(!rows.holds(MaerSyncSession.queueKey), "the window wrote under keys without an identity")
        // The pin reads again: the same account, its own state.
        box.identity = Self.byKey
        box.unknown = false
        #expect(session.rereadIfUnknown())
        #expect(session.identity == Self.byKey)
        #expect(session.stands["rss:a:1"] == [1, 1_000])
    }

    @Test("a session that knows its account by the key does not switch to the address when the pin cannot be read at a reload")
    func reloadKeepsTheAccount() throws {
        let suite = "maer-pin-reload-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let box = Box()
        box.access = Self.access
        box.identity = Self.byKey
        let session = session(box, defaults: defaults)
        session.enqueue(upserts: ["rss:q:1": [2, 2_000]], removing: [], by: "witness")
        box.identity = nil
        box.unknown = true
        session.reloadAccess()
        #expect(session.identity != Self.byAddress, "the account was named by its address")
        #expect(session.accessUnknown)
    }

    @Test("a device whose access stood without a pin takes its state over to the fingerprint once the pin is held")
    func restoredDeviceCarries() throws {
        let suite = "maer-pin-restored-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rows = CarrierStandRows.matching(defaults)
        let box = Box()
        box.access = Self.access
        box.identity = Self.byAddress
        let session = session(box, defaults: defaults)
        session.enqueue(upserts: ["rss:w:1": [3, 3_000]], removing: [], by: "witness")
        #expect(rows.holds(Self.byAddress.keyed(MaerSyncSession.queueKey)), "the precondition: the window queued under the address")
        // The handshake held the pin: the identity is now the fingerprint.
        box.identity = Self.byKey
        session.reloadAccess()
        #expect(session.identity == Self.byKey)
        #expect(rows.holds(Self.byKey.keyed(MaerSyncSession.queueKey)), "the window's queue stayed under the address")
        #expect(!rows.holds(Self.byAddress.keyed(MaerSyncSession.queueKey)))
    }

    @Test("Fence: no reader asks the pin the old way; the settings page says when the held key cannot be read", .needsTheSources)
    func noOldReader() throws {
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = SyncContractFenceTests.stripped(try SourceTree.text(file))
            #expect(!text.contains("ServiceKeyPin.held("), "\(file.lastPathComponent) reads an unreadable pin as none")
        }
        let page = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
            .appendingPathComponent("Sources/Views/MaerSyncSettingsView.swift"), encoding: .utf8))
        #expect(page.contains("Text(\"The stored key cannot be read right now.\")"))
    }
}
