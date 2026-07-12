import SwiftUI
import WidgetKit

/// Home-Screen-Widget „Als Nächstes": zeigt die nächsten Folgen der Podcast-
/// Queue (Titel + Show). Daten kommen als Snapshot aus dem App-Group-Container
/// (siehe `PodcastQueueSnapshot` in WidgetShared.swift); die App stößt bei jeder
/// Queue-Änderung einen Reload an. Diese Datei gehört NUR zum Widget-Target.
struct PodcastUpNextEntry: TimelineEntry {
    let date: Date
    let items: [PodcastQueueSnapshot.Item]
}

struct PodcastUpNextProvider: TimelineProvider {
    private func currentEntry() -> PodcastUpNextEntry {
        PodcastUpNextEntry(date: Date(), items: PodcastQueueSnapshot.load()?.items ?? [])
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
        .description("Your podcast queue at a glance.")
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
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.title2).foregroundStyle(.secondary)
            Text("Queue is empty").font(.caption).foregroundStyle(.secondary)
        }
    }
}
