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
/// medium show one row per title the settings ask for: the rows the app
/// wrote (`ContinueRows`) with the snapshot's title laid in. A tap opens
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
    /// The rows the app's home pass wrote, without the snapshot's title,
    /// and when that pass ran.
    var homeRows: [WidgetSourceRow] = []
    var passAtMs: Double?
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
        let pass = ContinueRows.load()
        let homeRows = pass?.rows ?? []
        var rowCovers: [String: UIImage] = [:]
        for name in homeRows.compactMap(\.cover) {
            if let url = WidgetCoverStore.continueRows.url(named: name), let data = try? Data(contentsOf: url) {
                rowCovers[name] = UIImage(data: data)
            }
        }
        return ContinueListeningEntry(date: Date(), snapshot: snapshot, cover: cover, layout: layout,
                                      homeRows: homeRows, passAtMs: pass?.passAtMs, rowCovers: rowCovers)
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
                                   cover: now.cover, layout: now.layout, homeRows: now.homeRows,
                                   passAtMs: now.passAtMs, rowCovers: now.rowCovers)
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
        WidgetRows.shown(WidgetRows.withTitle(of: entry.snapshot, at: entry.date, in: entry.homeRows,
                                              passAtMs: entry.passAtMs),
                         layout: entry.layout, accessibilitySize: dynamicTypeSize.isAccessibilitySize)
    }

    /// Large and medium are the sizes with text over the cover and with rows.
    private var isWide: Bool {
        family == .systemLarge || family == .systemMedium
    }

    private var face: ContinueFace {
        ContinueFace.of(showsRowsAtThisSize: isWide, hasRows: !rows.isEmpty, hasSnapshot: entry.snapshot != nil)
    }

    /// The medium widget while a title plays: the title and the rows beside
    /// it (`WidgetRows.splitsWhilePlaying`); nil keeps the one face.
    private var playingSplit: (snapshot: WidgetSnapshot, beside: [WidgetSourceRow])? {
        guard let snapshot = entry.snapshot else { return nil }
        let accessibility = dynamicTypeSize.isAccessibilitySize
        let beside = WidgetRows.besidePlaying(entry.homeRows, playing: snapshot.itemId,
                                              layout: entry.layout, accessibilitySize: accessibility)
        guard WidgetRows.splitsWhilePlaying(isMedium: family == .systemMedium, isPlaying: snapshot.isPlaying,
                                            accessibilitySize: accessibility, besideCount: beside.count) else {
            return nil
        }
        return (snapshot, beside)
    }

    var body: some View {
        Group {
            if let split = playingSplit {
                HStack(spacing: 12) {
                    playingHalf(split.snapshot)
                    // The half shows its cover already; the rows beside it
                    // give their width to the title.
                    rowsFace(split.beside, covers: false)
                }
            } else if face == .rows {
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

    /// The playing title in the medium widget's left half: its cover to the
    /// half's edges under the gradient, title and bar as in the small widget.
    /// A tap opens the app with the title.
    private func playingHalf(_ snapshot: WidgetSnapshot) -> some View {
        Link(destination: ResumeLink.url(itemId: snapshot.itemId)) {
            Color.clear
                .overlay { coverImage }
                .overlay { coverGradient(startingAt: 0.2) }
                .overlay(alignment: .bottomLeading) {
                    small(WidgetLine.of(snapshot, at: entry.date))
                        .padding(10)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Large and medium with rows: a heading, then one row per title. The
    /// rows share the whole height under the heading, each the same. A
    /// tap on a row opens the app with that title; its button continues
    /// the title without opening the app.
    private func rowsFace(_ rows: [WidgetSourceRow], covers: Bool = true) -> some View {
        let spacing: CGFloat = family == .systemLarge ? 12 : 8
        return VStack(alignment: .leading, spacing: spacing) {
            Label("Continue Listening", systemImage: "headphones")
                .font(.caption.bold())
                .foregroundStyle(.orange)
            GeometryReader { space in
                let height = WidgetRows.rowHeight(available: space.size.height, rows: rows.count, spacing: spacing)
                // Square, as tall as the row; the cap keeps the title its
                // room when one row has the whole widget.
                let side: CGFloat? = covers && !dynamicTypeSize.isAccessibilitySize
                    ? min(height, family == .systemLarge ? 140 : 96) : nil
                VStack(alignment: .leading, spacing: spacing) {
                    ForEach(rows, id: \.itemId) { row in
                        sourceRow(row, coverSide: side)
                            .frame(height: height)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The title stands on one line. The medium rows and the accessibility
    /// sizes keep only the time in the line under it, and the accessibility
    /// sizes drop the cover. A title nobody started has no bar and no time;
    /// under its name stands who made it, at every size. The kind's mark
    /// stands before the title, on its line.
    private func sourceRow(_ row: WidgetSourceRow, coverSide: CGFloat?) -> some View {
        let large = family == .systemLarge
        let compact = !large || dynamicTypeSize.isAccessibilitySize
        let started = row.isLive || row.showsProgress
        return HStack(spacing: 8) {
            Link(destination: ResumeLink.url(itemId: row.itemId)) {
                HStack(spacing: 8) {
                    if let coverSide {
                        rowCover(row)
                            .frame(width: coverSide, height: coverSide)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            rowKind(row)
                            Text(row.title)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                        }
                        rowDetail(row, compact: compact && started)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if row.showsProgress {
                            ProgressView(value: row.fraction ?? 0)
                                .tint(.orange)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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

    /// The row's kind in the colour of the line under the title: the
    /// symbol and the name the app's mark of a mixed row draws and reads.
    @ViewBuilder
    private func rowKind(_ row: WidgetSourceRow) -> some View {
        if let kind = row.kind {
            Image(systemName: kind.systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text(verbatim: kind.label))
        }
    }

    /// Who and how long, or live; compact, only how long or live. Beside a
    /// name the time keeps its width and the name gives way.
    private func rowDetail(_ row: WidgetSourceRow, compact: Bool) -> some View {
        let time = row.isLive ? String(localized: "Live") : row.showsProgress ? (row.remainingText ?? "") : ""
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

    /// A row's cover: its file in the app group, or, for the snapshot's
    /// title, the snapshot's cover.
    private func rowImage(_ row: WidgetSourceRow) -> UIImage? {
        if let name = row.cover, let image = entry.rowCovers[name] { return image }
        return row.itemId == entry.snapshot?.itemId ? entry.cover : nil
    }

    /// Square at the size the row offers.
    private func rowCover(_ row: WidgetSourceRow) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = rowImage(row) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay(Image(systemName: row.kindSymbol).font(.caption).foregroundStyle(.secondary))
                }
            }
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
            coverGradient(startingAt: isWide ? 0 : 0.2)
        }
    }

    /// As the cards on Start: from clear to the colour of the cover's own
    /// bottom edge, which the app wrote into the snapshot; a snapshot
    /// without it keeps a dark gradient.
    private func coverGradient(startingAt start: Double) -> some View {
        let tint = entry.snapshot?.coverTint.flatMap(Self.color(of:)) ?? .black.opacity(0.75)
        return LinearGradient(stops: [.init(color: .clear, location: start),
                                      .init(color: tint, location: 0.75),
                                      .init(color: tint, location: 1)],
                              startPoint: .top, endPoint: .bottom)
    }

    /// A colour from RGBA components; nil for any other count.
    private static func color(of components: [Double]) -> Color? {
        guard components.count == 4 else { return nil }
        return Color(red: components[0], green: components[1], blue: components[2], opacity: components[3])
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
