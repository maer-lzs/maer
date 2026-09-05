// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// THE door to the settings and choices. Every read and write of a stored
/// setting or choice goes through here (a fence keeps `UserDefaults.standard`
/// out of the rest of the app; the listening stock and the row stores have
/// doors of their own). The keys stay where they are born, in
/// `AppStorageKeys`, with their class (travels, device, machine); this is
/// the one place that touches the store for them.
///
/// Typed on purpose: a caller says what it expects, and the coercions that
/// used to be repeated at every site (`object(forKey:) as? Float ?? 1.0`)
/// live here once.
nonisolated extension AppStorageKeys {
    // MARK: Reads

    static func bool(_ key: String, default fallback: Bool = false) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    static func string(_ key: String) -> String? {
        UserDefaults.standard.string(forKey: key)
    }

    static func double(_ key: String) -> Double? {
        (UserDefaults.standard.object(forKey: key) as? NSNumber)?.doubleValue
    }

    static func float(_ key: String) -> Float? {
        (UserDefaults.standard.object(forKey: key) as? NSNumber)?.floatValue
    }

    static func int(_ key: String) -> Int? {
        (UserDefaults.standard.object(forKey: key) as? NSNumber)?.intValue
    }

    static func stringArray(_ key: String) -> [String]? {
        UserDefaults.standard.stringArray(forKey: key)
    }

    static func array(_ key: String) -> [Any]? {
        UserDefaults.standard.array(forKey: key)
    }

    static func dictionary(_ key: String) -> [String: Any]? {
        UserDefaults.standard.dictionary(forKey: key)
    }

    static func data(_ key: String) -> Data? {
        UserDefaults.standard.data(forKey: key)
    }

    static func object(_ key: String) -> Any? {
        UserDefaults.standard.object(forKey: key)
    }

    static func exists(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) != nil
    }

    /// The whole domain, for the scanners that walk every key (continue
    /// sources, listening classes). One reader, so the cost is visible.
    static func snapshot() -> [String: Any] {
        UserDefaults.standard.dictionaryRepresentation()
    }

    /// The store itself, for the pure helpers that take it as a parameter
    /// (a migration over a suite, a witness). Never for a read or a write
    /// at a call site; those go through the functions above.
    static var store: UserDefaults { .standard }

    // MARK: Writes

    /// Writes a value; nil removes the key. A choice that travels is noted
    /// by its own setter (the choice family needs the main actor); this
    /// door is the store, not the messenger.
    static func set(_ value: Any?, for key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    static func remove(_ key: String) {
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: Typed doors per setting, where a coercion or a default is the fact

    /// Skip interval in seconds for the spoken word; 30 when never set.
    static var skipIntervalValue: Double {
        get { double(skipInterval) ?? PlaybackSkip.standardInterval(for: .spokenWord) }
        set { set(newValue, for: skipInterval) }
    }

    /// Skip interval in seconds for music; 10 when never set.
    static var musicSkipIntervalValue: Double {
        get { double(musicSkipInterval) ?? PlaybackSkip.standardInterval(for: .music) }
        set { set(newValue, for: musicSkipInterval) }
    }

    /// The speed for titles without a rate of their own; 1.0 when never set.
    static var defaultPlaybackRateValue: Float {
        get { float(defaultPlaybackRate) ?? 1.0 }
        set { set(newValue, for: defaultPlaybackRate) }
    }

    static var autoPlayNextInSeriesValue: Bool {
        get { bool(autoPlayNextInSeries) }
        set { set(newValue, for: autoPlayNextInSeries) }
    }

    /// The standby pointer: the last played item, or nil.
    static var lastPlayedItemIdValue: String? {
        get { string(lastPlayedItemId) }
        set { set(newValue, for: lastPlayedItemId) }
    }
}
