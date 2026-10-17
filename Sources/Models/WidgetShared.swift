// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// App Group. Shared container of app and widget extension.
/// Forks: adapt to your own bundle structure (also change it in the
/// .entitlements files of BOTH targets).
nonisolated enum AppGroup {
    // The app's own group since the identity move completed; the old
    // bridge-era group died with the bridge app. The widget snapshot
    // regenerates on the next playback write.
    static let identifier = "group.fm.maer.app"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

/// Last-played book for the home-screen widget: the app writes (see
/// PlayerViewModel+Widget), the widget reads. Separate process, hence via the
/// App Group container. File belongs to BOTH targets.
nonisolated struct WidgetSnapshot: Codable {
    var itemId: String
    var title: String
    var author: String?
    /// 0…1 book progress at write time.
    var fraction: Double
    var remainingText: String?
    var isPlaying: Bool
    /// While playing: what the widget shows minute by minute from `savedAt`
    /// on, computed by the app, so the widget runs on by itself instead of
    /// the app reloading it every minute. Optional: a snapshot written
    /// before shows its saved values.
    var steps: [Step]?
    var savedAt: Double?

    struct Step: Codable, Equatable {
        var fraction: Double
        var remainingText: String?
    }

    /// One step per minute from `position`, at `rate`, for `minutes`
    /// minutes; the first is the position itself.
    static func steps(position: Double, duration: Double, rate: Double, minutes: Int,
                      remaining text: (Double) -> String?) -> [Step] {
        guard duration > 0 else { return [] }
        return (0...minutes).map { minute in
            let at = min(position + Double(minute) * 60 * rate, duration)
            return Step(fraction: min(max(at / duration, 0), 1), remainingText: text(max(duration - at, 0)))
        }
    }

    /// What the widget shows at `date`: the step of the minute since the
    /// write while playing, else the saved values.
    func shown(at date: Date) -> Step {
        guard isPlaying, let steps, !steps.isEmpty, let savedAt else {
            return Step(fraction: fraction, remainingText: remainingText)
        }
        let minute = Int(max(date.timeIntervalSince1970 - savedAt, 0) / 60)
        return steps[min(minute, steps.count - 1)]
    }

    /// Whether a snapshot written while playing at `savedAt` must be written
    /// anew at `now`: `margin` minutes before its `minutesAhead` steps run
    /// out, so the widget never stands on the last one. Nil (not written
    /// while playing) never.
    static func needsRenewal(savedAt: Double?, now: Double, minutesAhead: Int, margin: Int = 5) -> Bool {
        guard let savedAt else { return false }
        return now - savedAt >= Double(max(minutesAhead - margin, 1)) * 60
    }

    static var snapshotURL: URL? {
        AppGroup.containerURL?.appendingPathComponent("widget-snapshot.json")
    }
    /// Cover thumbnail as PNG next to the snapshot.
    static var coverURL: URL? {
        AppGroup.containerURL?.appendingPathComponent("widget-cover.png")
    }

    static func load() -> WidgetSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        guard let url = Self.snapshotURL, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Preview of the podcast "Up Next" queue for the home-screen widget. The app
/// writes on every queue change (see `PlayQueue.save`), the widget reads.
/// Via the App Group container, since it is a separate process.
nonisolated struct PodcastQueueSnapshot: Codable {
    struct Item: Codable {
        var title: String
        var show: String?
    }
    var items: [Item]

    static var url: URL? {
        AppGroup.containerURL?.appendingPathComponent("podcast-queue-snapshot.json")
    }

    static func load() -> PodcastQueueSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PodcastQueueSnapshot.self, from: data)
    }

    func save() {
        guard let url = Self.url, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
