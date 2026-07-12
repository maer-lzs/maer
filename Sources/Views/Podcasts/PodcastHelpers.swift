import SwiftUI
import Combine

/// Filter für die „Neue Folgen"-Inbox.
enum PodcastEpisodeFilter: String, CaseIterable, Identifiable {
    case new, inProgress, downloaded
    var id: String { rawValue }
    var label: LocalizedStringKey {
        switch self {
        case .new: return "New"
        case .inProgress: return "In Progress"
        case .downloaded: return "Downloaded"
        }
    }
}

/// PodcastShow + Episode → LibraryItem (quellen-agnostisch). Der Namespace im
/// `guid`/`id` (`rss:`/`abspod:`) routet Wiedergabe/Cover/Fortschritt auf die
/// richtige Quelle.
func podcastLibraryItem(show: PodcastShow, episode: PodcastEpisode) -> LibraryItem {
    LibraryItem(
        id: episode.guid,
        media: LibraryItemMedia(
            metadata: LibraryItemMetadata(
                title: episode.title, authorName: show.title, narratorName: nil,
                seriesName: show.title, genres: nil, publishedYear: nil,
                description: episode.description
            ),
            duration: episode.duration, chapters: nil,
            tracks: [ABSAudioTrack(index: 0, startOffset: nil, duration: episode.duration,
                                   contentUrl: episode.audioURL, metadata: nil)]
        ),
        addedAt: episode.pubDate
    )
}

/// Pro-Show-Auto-Download: lädt für aktivierte Shows die neuesten, seit dem
/// Einschalten erschienenen Folgen lokal (quellenübergreifend RSS + ABS). Nur
/// Folgen NACH dem Aktivierungszeitpunkt werden gezogen, damit vom Nutzer
/// gelöschte Altfolgen nicht endlos neu geladen werden.
@MainActor
enum PodcastAutoDownload {
    static func flagKey(_ showId: String) -> String { "podcastAutoDownload.\(showId)" }
    private static func sinceKey(_ showId: String) -> String { "podcastAutoDownloadSince.\(showId)" }

    static func isEnabled(_ showId: String) -> Bool {
        UserDefaults.standard.bool(forKey: flagKey(showId))
    }

    static func setEnabled(_ showId: String, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: flagKey(showId))
        // Beim Einschalten den Stichtag setzen → ab jetzt neue Folgen.
        if on { UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: sinceKey(showId)) }
    }

    /// Für alle aktivierten Shows die neuen (seit Stichtag), noch nicht lokal
    /// vorhandenen Folgen ziehen. `perShow` deckelt pro Durchlauf.
    static func run(shows: [PodcastShow], perShow: Int = 3) async {
        let dm = DownloadManager.shared
        for show in shows where isEnabled(show.id) {
            let since = UserDefaults.standard.double(forKey: sinceKey(show.id))
            let candidates = show.episodes
                .filter { $0.pubDate >= since }
                .sorted { $0.pubDate > $1.pubDate }
                .prefix(perShow)
                .map { podcastLibraryItem(show: show, episode: $0) }
            for item in candidates where !dm.isDownloaded(itemId: item.id) {
                let provider = AppSession.shared.provider(for: item.id)
                guard let detail = try? await provider.fetchItemDetail(itemId: item.id) else { continue }
                await dm.download(item: detail, provider: provider)
            }
        }
    }
}

/// Feed-only-Folge einer ABS-Show → abspielbares `rss:`-Item: streamt vom
/// Original-Host, Fortschritt läuft lokal+iCloud (kein Server-Download nötig).
/// Gleiche `rss:<feedKey>:<guid>`-ID wie RSS/PodcastIndex → gemeinsamer
/// Fortschritt, und die Basis für den späteren Server-Handoff.
@MainActor
func feedEpisodePlayItem(show: PodcastShow, feed: FeedEpisode) -> LibraryItem {
    let guid = "rss:\(PodcastSubscriptions.feedKey(show.feedURL)):\(feed.id)"
    return LibraryItem(
        id: guid,
        media: LibraryItemMedia(
            metadata: LibraryItemMetadata(
                title: feed.title, authorName: show.title, narratorName: nil,
                seriesName: show.title, genres: nil, publishedYear: nil, description: nil),
            duration: feed.duration, chapters: nil,
            tracks: [ABSAudioTrack(index: 0, startOffset: nil, duration: feed.duration,
                                   contentUrl: feed.enclosureUrl, metadata: nil)]),
        addedAt: feed.publishedAt)
}

// MARK: - Quellen-bewusster Gehört-Zustand

/// HTML aus Episodenbeschreibungen zu Plaintext entschärfen (Tags/Entities),
/// analog `BookDetailScreen.plainText(fromHTML:)`.
func podcastPlainText(_ html: String) -> String {
    var text = html
    text = text.replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
    text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.caseInsensitive, .regularExpression])
    text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    let entities = ["&amp;": "&", "&nbsp;": " ", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">"]
    for (entity, replacement) in entities {
        text = text.replacingOccurrences(of: entity, with: replacement)
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// „vor 2 Tagen" — relatives Datum aus `addedAt` (pubDate).
func relativeDateText(_ item: LibraryItem) -> String {
    guard let added = item.addedAt, added > 0 else { return "" }
    return Date(timeIntervalSince1970: added / 1000)
        .formatted(.relative(presentation: .named))
}

/// „55 min" bzw. „1 Std 51 min" aus der Episodendauer.
func durationText(_ item: LibraryItem) -> String {
    let total = Int((item.media?.duration ?? 0) / 60)
    if total >= 60 {
        return String(localized: "\(total / 60) h \(total % 60) min")
    }
    return String(localized: "\(total) min")
}

/// Podcast-Cover (Remote-URL) mit Fallback-Mikrofon. `thumbnailPixel` erzwingt
/// ein Thumbnail dieser Zielgröße (z. B. 800 px für die „Als Nächstes"-Karten —
/// scharf, aber viel leichter als der Voll-Decode bis ~2200 px).
@ViewBuilder
func podcastArtwork(url: URL?, size: CGFloat, corner: CGFloat, thumbnailPixel: CGFloat? = nil) -> some View {
    let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
    Group {
        if let url {
            CachedAsyncImage(url: url,
                             useThumbnail: thumbnailPixel != nil || size <= 200,
                             thumbnailMaxPixel: thumbnailPixel) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                shape.fill(Color.secondary.opacity(0.15))
            }
        } else {
            shape.fill(Color.secondary.opacity(0.15))
                .overlay(Image(systemName: "mic").font(.title3).foregroundStyle(.secondary))
        }
    }
    .frame(width: size, height: size)
    .clipShape(shape)
}
