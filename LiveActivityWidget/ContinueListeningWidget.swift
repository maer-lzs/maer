// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import WidgetKit

/// Home-screen widget "Continue": shows the last played book with cover,
/// progress and remaining time; a tap opens the app and resumes (maer://resume
/// → ResumeRequest path). Data comes as a snapshot from the App Group container
/// (see WidgetShared.swift, belongs to both targets); the app triggers reloads
/// on play/pause/book change. This file belongs ONLY to the widget extension
/// target.
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
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct ContinueListeningView: View {
    let entry: ContinueListeningEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                switch family {
                case .systemMedium: medium(snapshot)
                default: small(snapshot)
                }
            } else {
                empty
            }
        }
        .containerBackground(for: .widget) {
            if entry.snapshot != nil {
                coverBackground
            } else {
                Color(.systemBackground)
            }
        }
    }

    /// Small and medium: the cover is the widget's background, which the
    /// system draws to every edge whatever its content margins are on this
    /// device; the text and the progress bar stand at the bottom inside
    /// those margins.
    private func small(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            Text(snapshot.title)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .lineLimit(2)
            ProgressView(value: snapshot.shown(at: entry.date).fraction)
                .tint(.orange)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
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
    private func medium(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Spacer(minLength: 0)
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
            // The step of this entry's minute while playing.
            let shown = snapshot.shown(at: entry.date)
            if let remaining = shown.remainingText {
                Text(remaining)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
            }
            ProgressView(value: shown.fraction)
                .tint(.orange)
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
            Rectangle()
                .fill(.quaternary)
                .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
        }
    }

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
