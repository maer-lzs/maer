// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// App Group — shared container of app and widget extension.
/// Forks: adapt to your own bundle structure (also change it in the
/// .entitlements files of BOTH targets).
nonisolated enum AppGroup {
    static let identifier = "group.de.lzs.ABSPlayer"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

/// Last-played book for the home-screen widget: the app writes (see
/// PlayerViewModel+Widget), the widget reads — separate process, hence via the
/// App Group container. File belongs to BOTH targets.
nonisolated struct WidgetSnapshot: Codable {
    var itemId: String
    var title: String
    var author: String?
    /// 0…1 book progress at write time.
    var fraction: Double
    var remainingText: String?
    var isPlaying: Bool

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
/// writes on every queue change (see `PlayQueue.save`), the widget reads —
/// via the App Group container, since it is a separate process.
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
