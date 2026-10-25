// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import WidgetKit

/// Home-screen widget "Up Next": shows the next entries of the play queue,
/// books, songs and episodes alike (title + show or artist; the medium size
/// with each entry's cover from the thumbnails the app leaves beside the
/// snapshot). Data comes as a snapshot from the App Group container (see
/// `PodcastQueueSnapshot` in WidgetShared.swift); the app triggers a reload on
/// every queue change. This file belongs ONLY to the widget target.
struct PodcastUpNextEntry: TimelineEntry {
    let date: Date
    let items: [PodcastQueueSnapshot.Item]
    /// The cover thumbnails the app left in the app group, by file name.
    var covers: [String: UIImage] = [:]
}

struct PodcastUpNextProvider: TimelineProvider {
    private func currentEntry() -> PodcastUpNextEntry {
        let items = PodcastQueueSnapshot.load()?.items ?? []
        var covers: [String: UIImage] = [:]
        for name in items.compactMap(\.cover) {
            if let url = PodcastQueueSnapshot.coverURL(named: name), let data = try? Data(contentsOf: url) {
                covers[name] = UIImage(data: data)
            }
        }
        return PodcastUpNextEntry(date: Date(), items: items, covers: covers)
    }
    func placeholder(in context: Context) -> PodcastUpNextEntry {
        PodcastUpNextEntry(date: Date(), items: [])
    }
    func getSnapshot(in context: Context, completion: @escaping (PodcastUpNextEntry) -> Void) {
        completion(currentEntry())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PodcastUpNextEntry>) -> Void) {
        completion(Timeline(entries: [currentEntry()], policy: .never))
    }
}

struct PodcastUpNextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PodcastUpNext", provider: PodcastUpNextProvider()) { entry in
            PodcastUpNextView(entry: entry)
        }
        .configurationDisplayName("Up Next")
        .description("What plays next, at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct PodcastUpNextView: View {
    let entry: PodcastUpNextEntry
    @Environment(\.widgetFamily) private var family

    private var visibleCount: Int { family == .systemMedium ? 4 : 3 }

    var body: some View {
        Group {
            if entry.items.isEmpty { empty } else { content }
        }
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: family == .systemMedium ? 7 : 5) {
            HStack(spacing: 5) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward").font(.caption2)
                Text("Up Next").font(.caption.bold())
                Spacer()
                if entry.items.count > visibleCount {
                    Text("+\(entry.items.count - visibleCount)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.orange)

            ForEach(Array(entry.items.prefix(visibleCount).enumerated()), id: \.offset) { _, it in
                if family == .systemMedium {
                    // Medium: each entry as a list row of the app, its
                    // cover small to the left of title and show.
                    HStack(spacing: 8) {
                        cover(it)
                        lines(it)
                    }
                } else {
                    lines(it)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func lines(_ it: PodcastQueueSnapshot.Item) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(it.title)
                .font(.caption.weight(.medium))
                .lineLimit(family == .systemMedium ? 1 : 2)
            if let show = it.show {
                Text(show)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// The entry's cover, or the app's placeholder for its kind. No
    /// taller than the two lines beside it, so the rows keep their height.
    @ViewBuilder
    private func cover(_ it: PodcastQueueSnapshot.Item) -> some View {
        let side: CGFloat = 26
        if let name = it.cover, let image = entry.covers[name] {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .frame(width: side, height: side)
                .overlay(Image(systemName: it.placeholder ?? "waveform")
                    .font(.caption2)
                    .foregroundStyle(.secondary))
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.title2).foregroundStyle(.secondary)
            Text("Queue is empty").font(.caption).foregroundStyle(.secondary)
        }
    }
}
