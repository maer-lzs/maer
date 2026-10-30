// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import AppIntents
import Foundation
import OSLog

/// The command behind the play button of the wide widget, the round widget
/// and the control: continue the last played title without opening the
/// app. As an audio command it runs in the app's process, which the system
/// starts in the background when it is not running; the app gives the
/// command its work (`handler`) when it starts. Without it, in the widget's
/// process, the command writes a line and does nothing.
struct ResumeListeningIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Continue Listening"
    static let description = IntentDescription("Continues the last played title.")
    /// Not listed in Shortcuts or the search: Siri's "Continue Listening"
    /// (`ContinueListeningIntent`) is the one action of that name there.
    static let isDiscoverable = false

    @MainActor static var handler: (@MainActor () async -> Void)?

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let handler = Self.handler else {
            WidgetLog.logger.notice("RESUME command without the app's handler")
            return .result()
        }
        await handler()
        return .result()
    }
}

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
    /// The symbol of the title's kind, written by the app, which knows the
    /// kinds (`MediaFamily.placeholderSymbol`). Nil in a snapshot that
    /// does not carry it.
    var kindSymbol: String?
    /// A live station: it has no end, so no progress and no time left.
    /// Nil in a snapshot that does not carry it.
    var isLive: Bool?

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

    /// The snapshot the app writes for its current title, nil while there
    /// is nothing to show (a title whose length is not known yet). A live
    /// station has no length: it is written as live, without progress and
    /// time left, whatever its position says.
    static func of(itemId: String, title: String, author: String?, kindSymbol: String, isLive: Bool,
                   position: Double, duration: Double, rate: Double, isPlaying: Bool, now: Double,
                   minutesAhead: Int, remaining text: (Double) -> String?) -> WidgetSnapshot? {
        if isLive {
            return WidgetSnapshot(itemId: itemId, title: title, author: author, fraction: 0, remainingText: nil,
                                  isPlaying: isPlaying, steps: nil, savedAt: now, kindSymbol: kindSymbol, isLive: true)
        }
        guard duration > 0 else { return nil }
        return WidgetSnapshot(
            itemId: itemId, title: title, author: author,
            fraction: min(max(position / duration, 0), 1),
            remainingText: text(max(duration - position, 0)),
            isPlaying: isPlaying,
            steps: isPlaying
                ? steps(position: position, duration: duration, rate: rate, minutes: minutesAhead, remaining: text)
                : nil,
            savedAt: now, kindSymbol: kindSymbol, isLive: false)
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
        guard let url = Self.snapshotURL else {
            WidgetLog.logger.error("WIDGET snapshot not written: no app group container")
            return
        }
        do {
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
        } catch {
            WidgetLog.logger.error("WIDGET snapshot not written: \(String(describing: error), privacy: .public)")
        }
    }
}

/// The log of the shared widget files, in app and widget alike; each
/// process names its own subsystem by its bundle.
nonisolated enum WidgetLog {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "fm.maer.app", category: "widget")
}

/// What a widget shows of a snapshot at a moment, the same for every
/// family: the kind's symbol, the title, and either the progress with the
/// time left or the mark of a live station.
nonisolated struct WidgetLine: Equatable {
    var symbol: String
    var title: String
    /// 0…1; nil for a live station.
    var fraction: Double?
    /// Nil for a live station or when not known.
    var remainingText: String?
    var isLive: Bool

    /// The symbol of a snapshot that carries none, the same one the app
    /// gives a title of no known kind.
    static let unknownKindSymbol = "waveform"

    static func of(_ snapshot: WidgetSnapshot, at date: Date) -> WidgetLine {
        let symbol = snapshot.kindSymbol ?? unknownKindSymbol
        if snapshot.isLive == true {
            return WidgetLine(symbol: symbol, title: snapshot.title, fraction: nil, remainingText: nil, isLive: true)
        }
        let shown = snapshot.shown(at: date)
        return WidgetLine(symbol: symbol, title: snapshot.title, fraction: shown.fraction,
                          remainingText: shown.remainingText, isLive: false)
    }
}

/// The sources the large and medium "Continue" have a row for: the app's
/// tabs. The raw values are the tabs' (`MediaType`), so the app hands a
/// title's tab over as its source and never assigns sources a second way.
nonisolated enum WidgetSource: String, Codable, CaseIterable, Sendable {
    case audiobooks
    case podcasts
    case music
    case radio
}

/// One title of the large and medium "Continue", written by the app.
nonisolated struct WidgetSourceRow: Codable, Equatable, Sendable {
    var source: WidgetSource
    var itemId: String
    var title: String
    var subtitle: String?
    /// 0…1; nil for a live station.
    var fraction: Double?
    var remainingText: String?
    var isLive: Bool
    var kindSymbol: String
    /// The row's cover file in the app group; nil while there is none.
    var cover: String?
    /// When the title was last heard, in milliseconds.
    var playedAt: Double
}

/// Which rows a large or medium "Continue" shows, from its settings and
/// the type size. Pure, the same for the widget and its witnesses.
nonisolated enum WidgetRows {
    enum Layout: Equatable, Sendable {
        /// The newest title of every source that is switched on, in the
        /// order of the app's tabs.
        case large(Set<WidgetSource>)
        /// The two titles heard last, from any source.
        case mediumRecent
        /// The newest title of each of two chosen sources, in that order.
        case mediumSources(WidgetSource, WidgetSource)
    }

    /// How many rows fit. At the accessibility type sizes a row needs its
    /// title on two lines, so fewer rows stand, and whole ones only.
    static func limit(large: Bool, accessibilitySize: Bool) -> Int {
        switch (large, accessibilitySize) {
        case (true, false): return 4
        case (true, true): return 2
        case (false, false): return 2
        case (false, true): return 1
        }
    }

    /// The order of the rows: heard last first, ties by id, so the same
    /// rows always come out the same way.
    static func heardLater(_ lhs: WidgetSourceRow, _ rhs: WidgetSourceRow) -> Bool {
        lhs.playedAt != rhs.playedAt ? lhs.playedAt > rhs.playedAt : lhs.itemId < rhs.itemId
    }

    static func shown(_ rows: [WidgetSourceRow], layout: Layout, accessibilitySize: Bool) -> [WidgetSourceRow] {
        let newestFirst = rows.sorted(by: heardLater)
        let newest = { (source: WidgetSource) in newestFirst.first { $0.source == source } }
        switch layout {
        case .large(let switchedOn):
            let picked = WidgetSource.allCases.filter { switchedOn.contains($0) }.compactMap(newest)
            return Array(picked.prefix(limit(large: true, accessibilitySize: accessibilitySize)))
        case .mediumRecent:
            return Array(newestFirst.prefix(limit(large: false, accessibilitySize: accessibilitySize)))
        case .mediumSources(let first, let second):
            let picked = (first == second ? [first] : [first, second]).compactMap(newest)
            return Array(picked.prefix(limit(large: false, accessibilitySize: accessibilitySize)))
        }
    }
}

/// Preview of the podcast "Up Next" queue for the home-screen widget. The app
/// writes on every queue change (see `PlayQueue.save`), the widget reads.
/// Via the App Group container, since it is a separate process.
nonisolated struct PodcastQueueSnapshot: Codable {
    struct Item: Codable {
        var title: String
        var show: String?
        /// The file of the entry's cover thumbnail in the app group
        /// (`coverName(for:)`); the medium widget shows it when it is there.
        var cover: String?
        /// The app's placeholder symbol for the entry's kind, shown while
        /// there is no cover.
        var placeholder: String?
    }
    var items: [Item]

    /// How many entries the medium widget lists with their covers; the app
    /// leaves a thumbnail for each of them.
    static let coveredCount = 4
    /// The thumbnail's longest side in pixels: the cover stands 26 pt high
    /// in the widget, at three pixels per point with room to spare.
    static let coverPixel: CGFloat = 96
    static let coverPrefix = "upnext-cover-"

    static var url: URL? {
        AppGroup.containerURL?.appendingPathComponent("podcast-queue-snapshot.json")
    }

    /// The thumbnail file of an entry: a stable name from its id (FNV-1a),
    /// so a queue that only reorders keeps its files.
    static func coverName(for id: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return coverPrefix + String(hash, radix: 16) + ".png"
    }

    static func coverURL(named name: String) -> URL? {
        AppGroup.containerURL?.appendingPathComponent(name)
    }

    /// The cover files to remove: every thumbnail of the queue the
    /// snapshot no longer names.
    static func staleCovers(in names: [String], keeping kept: Set<String>) -> [String] {
        names.filter { $0.hasPrefix(coverPrefix) && !kept.contains($0) }.sorted()
    }

    static func writeCover(_ data: Data, named name: String) -> Bool {
        guard let url = coverURL(named: name) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
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
