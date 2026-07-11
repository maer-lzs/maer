import SwiftUI

/// Podcast-Tab: „Neueste Folgen" (Inbox aller Abos, chronologisch) plus
/// Raster der abonnierten Shows → Tap = Folgenliste. Episoden sind normale
/// `LibraryItem`s, laufen also über den bestehenden Player/Coordinator.
struct PodcastsView: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var subs = PodcastSubscriptions.shared
    private var rss: RSSProvider { AppSession.shared.rssProvider }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                let latest = rss.latestEpisodeItems()
                if !latest.isEmpty {
                    section(title: String(localized: "Latest Episodes")) {
                        ForEach(latest.prefix(20)) { item in
                            EpisodeRow(item: item, playerCoordinator: playerCoordinator)
                        }
                    }
                }

                section(title: String(localized: "Subscriptions")) {
                    ForEach(rss.showsWithEpisodes(), id: \.show.id) { entry in
                        NavigationLink {
                            PodcastShowView(
                                show: entry.show,
                                items: entry.items,
                                playerCoordinator: playerCoordinator
                            )
                        } label: {
                            ShowRow(show: entry.show, episodeCount: entry.items.count)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical)
        }
        .refreshable { await subs.refreshAll() }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3).bold().padding(.horizontal)
            content()
        }
    }
}

/// Show-Zeile im Abo-Bereich (Cover + Titel + Folgenzahl).
private struct ShowRow: View {
    let show: PodcastShow
    let episodeCount: Int

    var body: some View {
        HStack(spacing: 12) {
            artwork(url: show.artworkURL.flatMap { URL(string: $0) }, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(show.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text("\(episodeCount) episodes").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// Folgenliste einer Show.
struct PodcastShowView: View {
    let show: PodcastShow
    let items: [LibraryItem]
    @ObservedObject var playerCoordinator: PlayerCoordinator

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    EpisodeRow(item: item, playerCoordinator: playerCoordinator)
                    Divider().padding(.leading, 80)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(show.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Eine Episoden-Zeile (Cover + Show·Folge + Datum/Restzeit). Tap spielt ab.
struct EpisodeRow: View {
    let item: LibraryItem
    @ObservedObject var playerCoordinator: PlayerCoordinator

    var body: some View {
        Button {
            Task { await playerCoordinator.open(item: item) }
        } label: {
            HStack(spacing: 12) {
                artwork(url: AppSession.shared.rssProvider.coverURL(forItemId: item.id), size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2)
                    HStack(spacing: 6) {
                        if let date = item.addedAt, date > 0 {
                            Text(Date(timeIntervalSince1970: date / 1000)
                                .formatted(.dateTime.day().month()))
                        }
                        if let duration = item.media?.duration, duration > 0 {
                            Text("· \(Int(duration / 60)) min")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Kleines Cover mit Fallback (Podcast-Artwork ist eine Remote-URL).
@ViewBuilder
private func artwork(url: URL?, size: CGFloat) -> some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    Group {
        if let url {
            CachedAsyncImage(url: url, useThumbnail: true) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                shape.fill(Color.secondary.opacity(0.15))
            }
        } else {
            shape.fill(Color.secondary.opacity(0.15))
                .overlay(Image(systemName: "mic").foregroundStyle(.secondary))
        }
    }
    .frame(width: size, height: size)
    .clipShape(shape)
}
