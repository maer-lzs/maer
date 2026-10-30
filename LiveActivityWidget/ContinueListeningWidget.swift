// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import WidgetKit

/// Widget "Continue": shows the last played title, on the home screen with
/// cover, progress and remaining time, on the lock screen wide and round in
/// one tone; a live station shows "Live" instead of progress. A tap opens
/// the app and resumes (maer://resume → ResumeRequest path). Data comes as
/// a snapshot from the App Group container (see WidgetShared.swift, belongs
/// to both targets); the app triggers reloads on play/pause/book change.
/// This file belongs ONLY to the widget extension target.
struct ContinueListeningEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let cover: UIImage?
}

struct ContinueListeningProvider: TimelineProvider {
    private func currentEntry() -> ContinueListeningEntry {
        let snapshot = WidgetSnapshot.load()
        var cover: UIImage?
        if let url = WidgetSnapshot.coverURL, let data = try? Data(contentsOf: url) {
            cover = UIImage(data: data)
        }
        return ContinueListeningEntry(date: Date(), snapshot: snapshot, cover: cover)
    }

    func placeholder(in context: Context) -> ContinueListeningEntry {
        ContinueListeningEntry(date: Date(), snapshot: nil, cover: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (ContinueListeningEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueListeningEntry>) -> Void) {
        // The app reloads on state changes only. While playing, the
        // snapshot carries a step per minute for the next hour, and the
        // widget runs on by itself: one entry per minute from now.
        let now = currentEntry()
        guard let snapshot = now.snapshot, snapshot.isPlaying, let steps = snapshot.steps, let savedAt = snapshot.savedAt,
              steps.count > 1 else {
            completion(Timeline(entries: [now], policy: .never))
            return
        }
        let start = Date(timeIntervalSince1970: savedAt)
        let entries = (0..<steps.count).map { minute in
            ContinueListeningEntry(date: start.addingTimeInterval(Double(minute) * 60), snapshot: snapshot, cover: now.cover)
        }.filter { $0.date.addingTimeInterval(60) > Date() }
        completion(Timeline(entries: entries.isEmpty ? [now] : entries, policy: .never))
    }
}

struct ContinueListeningWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "ContinueListeningWidget",
            provider: ContinueListeningProvider()
        ) { entry in
            ContinueListeningView(entry: entry)
                .widgetURL(URL(string: "maer://resume"))
        }
        .configurationDisplayName("Continue Listening")
        .description("The last thing you played, one tap away.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

private struct ContinueListeningView: View {
    let entry: ContinueListeningEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                let line = WidgetLine.of(snapshot, at: entry.date)
                switch family {
                case .systemMedium: medium(snapshot, line)
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
            } else if entry.snapshot != nil {
                coverBackground
            } else {
                Color(.systemBackground)
            }
        }
    }

    private var isAccessory: Bool {
        family == .accessoryRectangular || family == .accessoryCircular
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
    /// play mark stands at the right; a tap opens the app and resumes.
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
            Spacer(minLength: 0)
            Image(systemName: "play.fill")
                .font(.body)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    /// Lock screen, round: the progress as a ring around the kind's
    /// symbol; a live station shows the symbol alone.
    private func circular(_ line: WidgetLine) -> some View {
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(line.title))
        .accessibilityValue(line.isLive ? Text("Live") : Text(line.remainingText ?? ""))
    }

    private var emptyAccessory: some View {
        Image(systemName: "headphones")
            .font(.title3)
            .accessibilityLabel(Text("Nothing playing yet"))
    }

    /// The cover with the shade that keeps the text readable. The medium
    /// widget carries four lines of text, so its shade starts at the top.
    private var coverBackground: some View {
        ZStack {
            coverImage
            LinearGradient(
                colors: family == .systemMedium ? [.black.opacity(0.2), .black.opacity(0.8)] : [.clear, .black.opacity(0.75)],
                startPoint: family == .systemMedium ? .top : .center, endPoint: .bottom
            )
        }
    }

    /// Medium: title, author, remaining time and bar at the bottom, over
    /// the cover.
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
            // The medium widget carries its text at the bottom left across
            // the width; the placeholder's mark stands at the right so the
            // title never lies on it.
            Rectangle()
                .fill(.quaternary)
                .overlay(alignment: family == .systemMedium ? .trailing : .center) {
                    Image(systemName: "book.closed")
                        .font(family == .systemMedium ? .largeTitle : .body)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, family == .systemMedium ? Self.placeholderInset : 0)
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
