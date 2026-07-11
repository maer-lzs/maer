import SwiftUI
import WidgetKit

/// Home-Screen-Widget „Weiterhören": zeigt das zuletzt gehörte Buch mit
/// Cover, Fortschritt und Restzeit; ein Tap öffnet die App und setzt fort
/// (maer://resume → ResumeRequest-Pfad). Daten kommen als Snapshot aus dem
/// App-Group-Container (siehe WidgetShared.swift, gehört beiden Targets);
/// die App stößt Reloads bei Play/Pause/Buchwechsel an.
/// Diese Datei gehört NUR zum Widget-Extension-Target.
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
        // Daten-getrieben: die App lädt bei Zustandswechseln neu — das
        // Widget selbst braucht keinen eigenen Rhythmus.
        completion(Timeline(entries: [currentEntry()], policy: .never))
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
        .description("The last played audiobook, one tap away.")
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
            Color(.systemBackground)
        }
    }

    /// Klein: Cover füllt das Widget, unten Titel + Fortschrittsbalken.
    private func small(_ snapshot: WidgetSnapshot) -> some View {
        ZStack(alignment: .bottom) {
            coverImage
            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .center, endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.title)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .lineLimit(2)
                ProgressView(value: snapshot.fraction)
                    .tint(.orange)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        // Bis in die Widget-Ecken (containerBackground-Ränder ausgleichen).
        .padding(-16)
    }

    /// Mittel: Cover links, rechts Titel/Autor/Restzeit/Balken.
    private func medium(_ snapshot: WidgetSnapshot) -> some View {
        HStack(spacing: 12) {
            coverImage
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.title)
                    .font(.subheadline.bold())
                    .lineLimit(2)
                if let author = snapshot.author {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                if let remaining = snapshot.remainingText {
                    Text(remaining)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: snapshot.fraction)
                    .tint(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
