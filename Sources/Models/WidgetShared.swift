// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import AppIntents
import Foundation
import OSLog
import WidgetKit

/// The command behind the play button of the wide widget, the round widget
/// and the control: continue the last played title without opening the
/// app, or the title a row of the large or medium widget names. As an audio
/// command it runs in the app's process, which the system starts in the
/// background when it is not running; the app gives the command its work
/// (`handler`) when it starts. Without it, in the widget's process, the
/// command writes a line and does nothing. When the app finds nothing to
/// continue, the command asks the system to bring the app to the front
/// (from iOS 26 on) and the app says so (`saysNothing`); before iOS 26 it
/// writes a line.
struct ResumeListeningIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Continue Listening"
    static let description = IntentDescription("Continues the last played title.")
    /// Not listed in Shortcuts or the search: Siri's "Continue Listening"
    /// (`ContinueListeningIntent`) is the one action of that name there.
    static let isDiscoverable = false

    /// The title a widget row names; nil continues the last played title.
    @Parameter(title: "Title")
    var itemId: String?

    init() {}

    init(itemId: String?) {
        self.itemId = itemId
    }

    /// Runs in the background; comes to the front only when it must say
    /// that there is nothing to continue.
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    /// The app's work; says whether it found something to continue.
    @MainActor static var handler: (@MainActor (String?) async -> Bool)?
    /// The app's sentence for nothing found, said once the app is in front.
    @MainActor static var saysNothing: (@MainActor () -> Void)?
    /// Brings the app to the front; a witness stands in for the system.
    @MainActor static var opensApp: (@MainActor (ResumeListeningIntent) async throws -> Bool) = { intent in
        guard #available(iOS 26.0, *) else { return false }
        try await intent.continueInForeground(nil, alwaysConfirm: false)
        return true
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let handler = Self.handler else {
            WidgetLog.logger.notice("RESUME command without the app's handler")
            return .result()
        }
        let found = await handler(itemId)
        guard !found else { return .result() }
        guard try await Self.opensApp(self) else {
            WidgetLog.logger.notice("RESUME command found nothing; the system cannot bring the app to the front")
            return .result()
        }
        Self.saysNothing?()
        return .result()
    }
}

/// The link a widget opens the app with to continue listening:
/// `maer://resume`, with the title a row names as its path. Built and read
/// only here, by the widget and the app. The path, not a query, because a
/// query is set only in `QueryValues`, which the widget does not build.
nonisolated enum ResumeLink {
    static let scheme = "maer"
    static let host = "resume"

    static func url(itemId: String?) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if let itemId { components.path = "/" + itemId }
        return components.url ?? URL(string: "\(scheme)://\(host)")!
    }

    /// Every link of the app's scheme asks to continue listening.
    static func asksToResume(_ url: URL) -> Bool {
        url.scheme == scheme
    }

    /// The title the link names; nil for none or an empty one.
    static func itemId(in url: URL) -> String? {
        guard asksToResume(url),
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path else { return nil }
        let id = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return id.isEmpty ? nil : id
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
    /// The title's source, written by the app, which knows the tabs
    /// (`ContinueBySource.source`). Nil in a snapshot that does not carry
    /// it; the title then joins no row of the large and medium widget.
    var source: WidgetSource?

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
                   source: WidgetSource? = nil,
                   position: Double, duration: Double, rate: Double, isPlaying: Bool, now: Double,
                   minutesAhead: Int, remaining text: (Double) -> String?) -> WidgetSnapshot? {
        if isLive {
            return WidgetSnapshot(itemId: itemId, title: title, author: author, fraction: 0, remainingText: nil,
                                  isPlaying: isPlaying, steps: nil, savedAt: now, kindSymbol: kindSymbol, isLive: true,
                                  source: source)
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
            savedAt: now, kindSymbol: kindSymbol, isLive: false, source: source)
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
nonisolated enum WidgetSource: String, Codable, CaseIterable, Sendable, AppEnum {
    case audiobooks
    case podcasts
    case music
    case radio

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Source"
    static let caseDisplayRepresentations: [WidgetSource: DisplayRepresentation] = [
        .audiobooks: "Audiobooks", .podcasts: "Podcasts", .music: "Music", .radio: "Radio",
    ]
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

    /// How many titles the medium widget shows when it shows the titles
    /// heard last; the rows keep at least that many besides the newest of
    /// each source.
    static let recentKept = 2

    /// The rows with `row` in them: its title once, and of the rest only
    /// what a widget can still show, the newest title of every source and
    /// the `recentKept` titles heard last.
    static func merged(_ row: WidgetSourceRow, into rows: [WidgetSourceRow]) -> [WidgetSourceRow] {
        let others: [WidgetSourceRow] = rows.filter { $0.itemId != row.itemId }
        let all = (others + [row]).sorted(by: heardLater)
        var seen = Set<WidgetSource>()
        var result: [WidgetSourceRow] = []
        for (index, candidate) in all.enumerated() {
            let newestOfSource = seen.insert(candidate.source).inserted
            if newestOfSource || index < recentKept { result.append(candidate) }
        }
        return result
    }

    /// The rows a widget shows: the rows the app's home pass wrote
    /// (`ContinueRows`), with the title of the player's snapshot in the row
    /// of its source. Each comes from its own writer, so neither can take
    /// the other's write away; the snapshot is the newer word on what plays
    /// here, a snapshot without a source joins no row.
    static func withTitle(of snapshot: WidgetSnapshot?, at date: Date, in rows: [WidgetSourceRow]) -> [WidgetSourceRow] {
        guard let snapshot, let source = snapshot.source else { return rows }
        let line = WidgetLine.of(snapshot, at: date)
        let row = WidgetSourceRow(source: source, itemId: snapshot.itemId, title: snapshot.title,
                                  subtitle: snapshot.author, fraction: line.fraction,
                                  remainingText: line.remainingText, isLive: line.isLive,
                                  kindSymbol: line.symbol, cover: nil,
                                  playedAt: (snapshot.savedAt ?? date.timeIntervalSince1970) * 1000)
        return merged(row, into: rows)
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

/// The rows of the large and medium "Continue", in their own file in the
/// app group, written by the app's home pass alone. The player writes only
/// its snapshot; the widget lays the snapshot's title into the rows when it
/// reads (`WidgetRows.withTitle`).
nonisolated struct ContinueRows: Codable, Equatable {
    var rows: [WidgetSourceRow]

    init(rows: [WidgetSourceRow]) {
        self.rows = rows
    }

    /// A row of another form (a field it lacks, a source this build does
    /// not know) is left out, the other rows still read; the next home pass
    /// writes the whole file anew.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rows = (try container.decodeIfPresent([LenientRow].self, forKey: .rows) ?? []).compactMap(\.row)
    }

    private struct LenientRow: Decodable {
        let row: WidgetSourceRow?

        init(from decoder: Decoder) throws {
            // bearable, because a row that does not read is one title fewer until the next pass
            row = try? WidgetSourceRow(from: decoder)
        }
    }

    static var url: URL? {
        AppGroup.containerURL?.appendingPathComponent("continue-rows.json")
    }

    static func load() -> ContinueRows? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ContinueRows.self, from: data)
    }

    /// Says whether the file was written; only `ContinueRowsWriter` calls it.
    func save() -> Bool {
        guard let url = Self.url, let data = try? JSONEncoder().encode(self) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}

/// What a "Continue" widget shows: its rows (large and medium, when it has
/// any), else the one last played title, and only without any snapshot
/// that nothing was played yet.
nonisolated enum ContinueFace: Equatable, Sendable {
    case rows
    case oneTitle
    case nothingYet

    static func of(showsRowsAtThisSize: Bool, hasRows: Bool, hasSnapshot: Bool) -> ContinueFace {
        if showsRowsAtThisSize, hasRows { return .rows }
        return hasSnapshot ? .oneTitle : .nothingYet
    }
}

/// What the medium "Continue" shows.
nonisolated enum ContinueMediumContent: String, Sendable, AppEnum {
    case lastHeard
    case twoSources

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Content"
    static let caseDisplayRepresentations: [ContinueMediumContent: DisplayRepresentation] = [
        .lastHeard: "Last Heard", .twoSources: "Two Sources",
    ]
}

/// The settings of the "Continue" widget, each size its own: the large one
/// switches sources on and off, the medium one shows the titles heard last
/// or the newest title of two chosen sources; the other sizes have none.
struct ContinueWidgetSettings: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Continue Listening"
    /// Settings of a widget, not an action: not listed in Shortcuts.
    static let isDiscoverable = false

    @Parameter(title: "Audiobooks", default: true)
    var audiobooks: Bool
    @Parameter(title: "Podcasts", default: true)
    var podcasts: Bool
    @Parameter(title: "Music", default: true)
    var music: Bool
    @Parameter(title: "Radio", default: true)
    var radio: Bool
    @Parameter(title: "Content", default: .lastHeard)
    var mediumContent: ContinueMediumContent
    @Parameter(title: "First Source", default: .audiobooks)
    var firstSource: WidgetSource
    @Parameter(title: "Second Source", default: .podcasts)
    var secondSource: WidgetSource

    static var parameterSummary: some ParameterSummary {
        When(widgetFamily: .equalTo, .systemLarge) {
            Summary {
                \.$audiobooks
                \.$podcasts
                \.$music
                \.$radio
            }
        } otherwise: {
            When(widgetFamily: .equalTo, .systemMedium) {
                When(\.$mediumContent, .equalTo, .twoSources) {
                    Summary {
                        \.$mediumContent
                        \.$firstSource
                        \.$secondSource
                    }
                } otherwise: {
                    Summary {
                        \.$mediumContent
                    }
                }
            } otherwise: {
                Summary()
            }
        }
    }

    /// The rows these settings ask for; `large` is the widget's size.
    func layout(large: Bool) -> WidgetRows.Layout {
        if large {
            let switchedOn: [WidgetSource: Bool] = [.audiobooks: audiobooks, .podcasts: podcasts, .music: music, .radio: radio]
            return .large(Set(WidgetSource.allCases.filter { switchedOn[$0] == true }))
        }
        return mediumContent == .twoSources ? .mediumSources(firstSource, secondSource) : .mediumRecent
    }
}

/// The cover thumbnails a widget reads from the app group, which loads
/// nothing from the network: one store per widget, told apart by the
/// prefix of its files, so one widget's clean-up never takes another's
/// covers.
nonisolated struct WidgetCoverStore: Sendable {
    let prefix: String
    /// The thumbnail's longest side in pixels.
    let pixel: CGFloat

    /// "Up Next": the cover stands 26 pt high in the widget, at three
    /// pixels per point with room to spare.
    static let upNext = WidgetCoverStore(prefix: "upnext-cover-", pixel: 96)
    /// The rows of the large and medium "Continue": the cover stands up
    /// to 44 pt high, at three pixels per point.
    static let continueRows = WidgetCoverStore(prefix: "continue-cover-", pixel: 132)

    /// The thumbnail file of a title: a stable name from its id (FNV-1a),
    /// so a list that only reorders keeps its files.
    func name(for id: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return prefix + String(hash, radix: 16) + ".png"
    }

    func url(named name: String) -> URL? {
        AppGroup.containerURL?.appendingPathComponent(name)
    }

    /// The cover files to remove: every thumbnail of this store the
    /// widget's snapshot no longer names.
    func stale(in names: [String], keeping kept: Set<String>) -> [String] {
        names.filter { $0.hasPrefix(prefix) && !kept.contains($0) }.sorted()
    }

    func write(_ data: Data, named name: String) -> Bool {
        guard let url = url(named: name) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
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
        /// (`WidgetCoverStore.upNext`); the medium widget shows it when it
        /// is there.
        var cover: String?
        /// The app's placeholder symbol for the entry's kind, shown while
        /// there is no cover.
        var placeholder: String?
    }
    var items: [Item]

    /// How many entries the medium widget lists with their covers; the app
    /// leaves a thumbnail for each of them.
    static let coveredCount = 4

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
