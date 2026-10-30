// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import AppIntents
import SwiftUI
import WidgetKit

/// Widget "Continue": shows the last played title, on the home screen with
/// cover, progress and remaining time, on the lock screen wide and round in
/// one tone; a live station shows "Live" instead of progress. Large and
/// medium show one row per title the settings ask for, once the app has
/// written rows (`WidgetSnapshot.bySource`). A tap opens
/// the app and resumes (maer://resume → ResumeRequest path). Data comes as
/// a snapshot from the App Group container (see WidgetShared.swift, belongs
/// to both targets); the app triggers reloads on play/pause/book change.
/// This file belongs ONLY to the widget extension target.
struct ContinueListeningEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let cover: UIImage?
    /// The rows the widget's settings ask for at its size.
    let layout: WidgetRows.Layout
    /// The covers of the rows the app left in the app group, by file name.
    var rowCovers: [String: UIImage] = [:]
}

struct ContinueListeningProvider: AppIntentTimelineProvider {
    private func currentEntry(_ layout: WidgetRows.Layout) -> ContinueListeningEntry {
        let snapshot = WidgetSnapshot.load()
        var cover: UIImage?
        if let url = WidgetSnapshot.coverURL, let data = try? Data(contentsOf: url) {
            cover = UIImage(data: data)
        }
        var rowCovers: [String: UIImage] = [:]
        for name in (snapshot?.bySource ?? []).compactMap(\.cover) {
            if let url = WidgetCoverStore.continueRows.url(named: name), let data = try? Data(contentsOf: url) {
                rowCovers[name] = UIImage(data: data)
            }
        }
        return ContinueListeningEntry(date: Date(), snapshot: snapshot, cover: cover, layout: layout, rowCovers: rowCovers)
    }

    private func layout(_ settings: ContinueWidgetSettings, _ context: Context) -> WidgetRows.Layout {
        settings.layout(large: context.family == .systemLarge)
    }

    func placeholder(in context: Context) -> ContinueListeningEntry {
        ContinueListeningEntry(date: Date(), snapshot: nil, cover: nil, layout: .mediumRecent)
    }

    func snapshot(for configuration: ContinueWidgetSettings, in context: Context) async -> ContinueListeningEntry {
        currentEntry(layout(configuration, context))
    }

    func timeline(for configuration: ContinueWidgetSettings, in context: Context) async -> Timeline<ContinueListeningEntry> {
        // The app reloads on state changes only. While playing, the
        // snapshot carries a step per minute for the next hour, and the
        // widget runs on by itself: one entry per minute from now.
        let now = currentEntry(layout(configuration, context))
        guard let snapshot = now.snapshot, snapshot.isPlaying, let steps = snapshot.steps, let savedAt = snapshot.savedAt,
              steps.count > 1 else {
            return Timeline(entries: [now], policy: .never)
        }
        let start = Date(timeIntervalSince1970: savedAt)
        let entries = (0..<steps.count).map { minute in
            ContinueListeningEntry(date: start.addingTimeInterval(Double(minute) * 60), snapshot: snapshot,
                                   cover: now.cover, layout: now.layout, rowCovers: now.rowCovers)
        }.filter { $0.date.addingTimeInterval(60) > Date() }
        return Timeline(entries: entries.isEmpty ? [now] : entries, policy: .never)
    }
}

struct ContinueListeningWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "ContinueListeningWidget",
            intent: ContinueWidgetSettings.self,
            provider: ContinueListeningProvider()
        ) { entry in
            ContinueListeningView(entry: entry)
                .widgetURL(ResumeLink.url(itemId: nil))
        }
        .configurationDisplayName("Continue Listening")
        .description("The last thing you played, one tap away.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular])
    }
}

private struct ContinueListeningView: View {
    let entry: ContinueListeningEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The rows the settings ask for at this size and type size.
    private var rows: [WidgetSourceRow] {
        WidgetRows.shown(entry.snapshot?.bySource ?? [], layout: entry.layout,
                         accessibilitySize: dynamicTypeSize.isAccessibilitySize)
    }

    /// Large and medium are the sizes with text over the cover and with rows.
    private var isWide: Bool {
        family == .systemLarge || family == .systemMedium
    }

    private var face: ContinueFace {
        ContinueFace.of(showsRowsAtThisSize: isWide, hasRows: !rows.isEmpty, hasSnapshot: entry.snapshot != nil)
    }

    var body: some View {
        Group {
            if face == .rows {
                rowsFace(rows)
            } else if face == .oneTitle, let snapshot = entry.snapshot {
                let line = WidgetLine.of(snapshot, at: entry.date)
                switch family {
                case .systemMedium, .systemLarge: medium(snapshot, line)
                case .accessoryRectangular: rectangular(line)
                case .accessoryCircular: circular(line)
                default: small(line)
                }
            } else {
                switch family {
                case .accessoryRectangular, .accessoryCircular: emptyAccessory
                default: empty
                }
            }
        }
        .containerBackground(for: .widget) {
            if isAccessory {
                // The lock screen draws its own material; a cover does not
                // carry in one tone.
                Color.clear
            } else if face == .oneTitle {
                coverBackground
            } else {
                Color(.systemBackground)
            }
        }
    }

    private var isAccessory: Bool {
        family == .accessoryRectangular || family == .accessoryCircular
    }

    /// Large and medium with rows: a heading, then one row per title. A
    /// tap on a row opens the app with that title; its button continues
    /// the title without opening the app.
    private func rowsFace(_ rows: [WidgetSourceRow]) -> some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 12 : 8) {
            Label("Continue Listening", systemImage: "headphones")
                .font(.caption.bold())
                .foregroundStyle(.orange)
            ForEach(rows, id: \.itemId) { row in
                sourceRow(row)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The title stands on one line. The medium rows and the accessibility
    /// sizes keep only the time in the line under it, and the accessibility
    /// sizes drop the cover.
    private func sourceRow(_ row: WidgetSourceRow) -> some View {
        let large = family == .systemLarge
        let compact = !large || dynamicTypeSize.isAccessibilitySize
        return HStack(spacing: 8) {
            Link(destination: ResumeLink.url(itemId: row.itemId)) {
                HStack(spacing: 8) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        rowCover(row, side: large ? 44 : 34)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        rowDetail(row, compact: compact)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if !row.isLive {
                            ProgressView(value: row.fraction ?? 0)
                                .tint(.orange)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            Button(intent: ResumeListeningIntent(itemId: row.itemId)) {
                Image(systemName: "play.circle.fill")
                    .font(compact ? .title3 : .title2)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel(Text("Continue Listening"))
            .accessibilityValue(Text(row.title))
        }
    }

    /// Who and how long, or live; compact, only how long or live. Beside a
    /// name the time keeps its width and the name gives way.
    private func rowDetail(_ row: WidgetSourceRow, compact: Bool) -> some View {
        let time = row.isLive ? String(localized: "Live") : (row.remainingText ?? "")
        let subtitle = compact ? nil : row.subtitle.flatMap { $0.isEmpty ? nil : $0 }
        return HStack(spacing: 0) {
            if let subtitle {
                Text(verbatim: subtitle)
                    .lineLimit(1)
                if !time.isEmpty {
                    Text(verbatim: " · ")
                        .fixedSize()
                        .accessibilityHidden(true)
                }
            }
            Text(verbatim: time)
                .lineLimit(1)
                .fixedSize(horizontal: subtitle != nil, vertical: false)
        }
    }

    private func rowCover(_ row: WidgetSourceRow, side: CGFloat) -> some View {
        Group {
            if let name = row.cover, let image = entry.rowCovers[name] {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay(Image(systemName: row.kindSymbol).font(.caption).foregroundStyle(.secondary))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    /// Small and medium: the cover is the widget's background, which the
    /// system draws to every edge whatever its content margins are on this
    /// device; the text and the progress bar stand at the bottom inside
    /// those margins.
    private func small(_ line: WidgetLine) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            Text(line.title)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .lineLimit(2)
            if line.isLive {
                liveMark
            } else {
                ProgressView(value: line.fraction ?? 0)
                    .tint(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    /// A live station in place of the time left and the bar.
    private var liveMark: some View {
        Text("Live")
            .font(.caption2.bold())
            .foregroundStyle(.white.opacity(0.85))
    }

    /// Lock screen, wide: the kind's symbol and the title in one line, the
    /// time left and the bar below; a live station says so instead. The
    /// play button at the right continues without opening the app; a tap
    /// beside it opens the app and resumes.
    private func rectangular(_ line: WidgetLine) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text(line.title).lineLimit(1)
                } icon: {
                    Image(systemName: line.symbol)
                }
                .font(.headline)
                if line.isLive {
                    Text("Live").font(.caption)
                } else {
                    if let remaining = line.remainingText {
                        // One line, as the bar below it: the width is the
                        // lock screen's and does not grow.
                        Text(remaining)
                            .font(.caption)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    ProgressView(value: line.fraction ?? 0)
                }
            }
            .layoutPriority(1)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button(intent: ResumeListeningIntent()) {
                Image(systemName: "play.fill")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Continue Listening"))
        }
    }

    /// Lock screen, round: the progress as a ring around the kind's
    /// symbol; a live station shows the symbol alone. The whole widget is
    /// the play button.
    private func circular(_ line: WidgetLine) -> some View {
        Button(intent: ResumeListeningIntent()) {
            circularFace(line)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(line.title))
        .accessibilityValue(line.isLive ? Text("Live") : Text(line.remainingText ?? ""))
        .accessibilityHint(Text("Continue Listening"))
    }

    private func circularFace(_ line: WidgetLine) -> some View {
        Group {
            if line.isLive {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: line.symbol).font(.title3)
                }
            } else {
                Gauge(value: line.fraction ?? 0) {
                    Image(systemName: line.symbol)
                }
                .gaugeStyle(.accessoryCircularCapacity)
            }
        }
    }

    private var emptyAccessory: some View {
        Image(systemName: "headphones")
            .font(.title3)
            .accessibilityLabel(Text("Nothing playing yet"))
    }

    /// The cover with the shade that keeps the text readable. Medium and
    /// large carry four lines of text, so their shade starts at the top.
    private var coverBackground: some View {
        ZStack {
            coverImage
            LinearGradient(
                colors: isWide ? [.black.opacity(0.2), .black.opacity(0.8)] : [.clear, .black.opacity(0.75)],
                startPoint: isWide ? .top : .center, endPoint: .bottom
            )
        }
    }

    /// Medium, and large without rows: title, author, remaining time and
    /// bar at the bottom, over the cover.
    private func medium(_ snapshot: WidgetSnapshot, _ line: WidgetLine) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.title)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let author = snapshot.author {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                if line.isLive {
                    liveMark
                } else if let remaining = line.remainingText {
                    Text(remaining)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            // Beside the placeholder's mark, never over it.
            .padding(.trailing, entry.cover == nil ? Self.placeholderRoom : 0)
            if !line.isLive {
                ProgressView(value: line.fraction ?? 0)
                    .tint(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    @ViewBuilder
    private var coverImage: some View {
        if let cover = entry.cover {
            Image(uiImage: cover)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            // Medium and large carry their text at the bottom left across
            // the width; the placeholder's mark stands at the right so the
            // title never lies on it.
            Rectangle()
                .fill(.quaternary)
                .overlay(alignment: isWide ? .trailing : .center) {
                    Image(systemName: "book.closed")
                        .font(isWide ? .largeTitle : .body)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, isWide ? Self.placeholderInset : 0)
                }
        }
    }

    /// The room the medium placeholder's mark keeps at the right: its
    /// distance from the edge, and the text's margin beside it.
    private static let placeholderInset: CGFloat = 24
    private static let placeholderRoom: CGFloat = 72

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "headphones")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Nothing playing yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
