// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// THE door to the shared cloud key-value store. Every family (choices,
/// claims, podcast pot, statistics, playlists, quota watch) takes its store
/// from here, so one rule holds for all of them at once:
///
/// A DEBUG build on the SIMULATOR gets an in-memory store, unless
/// `MAER_LIVE_KVS=1` stands in the environment. A simulator signed into a
/// real account can then never write into it, whatever test starts the
/// app and with whatever arguments. The per-family silence switches remain
/// as a second fence, but the door is the construction: seed stations in a
/// person's account were the cost of trusting a switch.
@MainActor
enum CloudKeyValue {
    static let store: any UserChoiceCloudStore = {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["MAER_LIVE_KVS"] != "1" {
            Logger.library.notice("KVS door: simulator DEBUG build, the shared store is in memory (MAER_LIVE_KVS=1 for live)")
            return InMemoryCloudStore()
        }
        #endif
        return NSUbiquitousKeyValueStore.default
    }()

    /// Whether the door leads to the real store.
    static var isLive: Bool { store is NSUbiquitousKeyValueStore }

    /// The sender to observe for external changes: the real store, or nil
    /// when the store is the in-memory one (which posts nothing).
    static var notificationObject: NSUbiquitousKeyValueStore? { store as? NSUbiquitousKeyValueStore }
}

/// The cloud key-value store as the families see it, injectable so a
/// two-device merge is provable in units (the store does not run on the
/// simulator; tests hand in a dictionary fake).
@MainActor
protocol UserChoiceCloudStore: AnyObject {
    func dictionary(forKey key: String) -> [String: Any]?
    func array(forKey key: String) -> [Any]?
    func set(_ value: Any?, forKey key: String)
    func synchronize() -> Bool
    /// Every key the store holds. The claim family keeps one key per
    /// device and reads all of them.
    var dictionaryRepresentation: [String: Any] { get }
    func removeObject(forKey key: String)
}

extension NSUbiquitousKeyValueStore: UserChoiceCloudStore {}

/// The in-memory store behind the door. Speaks the same protocol as the
/// real one; nothing leaves the process.
@MainActor
final class InMemoryCloudStore: UserChoiceCloudStore {
    private var values: [String: Any] = [:]

    init() {}

    func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
    func array(forKey key: String) -> [Any]? { values[key] as? [Any] }
    func set(_ value: Any?, forKey key: String) {
        if let value { values[key] = value } else { values.removeValue(forKey: key) }
    }
    func synchronize() -> Bool { true }
    var dictionaryRepresentation: [String: Any] { values }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}
