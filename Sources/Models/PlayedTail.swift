// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// How close to the end an episode or a book counts as played. Credits and
/// outros make the last minute rarely heard, and a finished title used to
/// linger in Continue with "0 min left".
///
/// A choice with three levels: the title (a book, or an episode's show),
/// else the general one, else one minute. The general value and the value per
/// show or book travel like the other per-show settings. "Off" is the old
/// behaviour: played at the last second.
nonisolated enum PlayedTail {
    /// The offered values in seconds; 0 is "off".
    static let choices: [Double] = [0, 30, 60, 120, 300]
    static let standard: Double = 60

    static let generalKey = "playedTailSeconds"
    static let prefix = "playedTail."
    static func key(_ id: String) -> String { prefix + id }

    /// Posted after any of the three levels changed, so the surfaces that
    /// derived a played state read it again.
    static let didChange = Notification.Name("PlayedTailDidChange")

    /// The value that applies: the title's own, else the general one, else
    /// the standard. An unknown stored value falls back the same way.
    static func effective(own: Double?, general: Double?) -> Double {
        if let own, choices.contains(own) { return own }
        if let general, choices.contains(general) { return general }
        return standard
    }

    /// The level a title reads its own value from: a podcast episode reads
    /// its show's, anything else (a book, a catalogue work) its own id.
    static func ownerId(forItemId id: String) -> String {
        AppStorageKeys.podcastShowId(forEpisodeId: id) ?? id
    }

    static func seconds(forItemId id: String, defaults: UserDefaults = .standard) -> Double {
        effective(own: stored(ownerId(forItemId: id), defaults: defaults),
                  general: defaults.object(forKey: generalKey) as? Double)
    }

    /// The show's or book's own value, nil when it follows the general one.
    static func stored(_ ownerId: String, defaults: UserDefaults = .standard) -> Double? {
        (defaults.object(forKey: key(ownerId)) as? Double).flatMap { choices.contains($0) ? $0 : nil }
    }

    /// The general value, the standard when none was chosen.
    static func general(defaults: UserDefaults = .standard) -> Double {
        effective(own: nil, general: defaults.object(forKey: generalKey) as? Double)
    }

    /// A chosen value, stored and said to the other devices; nil lets a
    /// show or book follow the general value again. `ownerId` nil is the
    /// general value. A value already in force writes nothing.
    @MainActor
    static func set(_ seconds: Double?, ownerId: String?) {
        let key = ownerId.map(key) ?? generalKey
        let current = AppStorageKeys.double(key)
        guard current != seconds else { return }
        if let seconds { AppStorageKeys.set(seconds, for: key) } else { AppStorageKeys.remove(key) }
        AppStorageKeys.noteChoice(seconds, key: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
