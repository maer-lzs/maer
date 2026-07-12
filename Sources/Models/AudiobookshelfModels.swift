import Foundation

// MARK: - Authorisierung / Nutzer

struct ABSUser: Decodable {
    let id: String
    let username: String
}

/// Antwort von /api/me — enthält alle Fortschritts-Einträge des Nutzers.
/// Antwort von POST /login. Ältere Server liefern den langlebigen `token`,
/// neuere (JWT-Auth ab v2.26) einen `accessToken` — beide Felder optional,
/// verwendet wird bevorzugt der langlebige.
struct LoginResponse: Decodable {
    let user: LoginUser
}

struct LoginUser: Decodable {
    let token: String?
    let accessToken: String?
}

struct MeResponse: Decodable {
    let mediaProgress: [MediaProgressEntry]?
    let bookmarks: [ABSBookmark]?
}

/// Lesezeichen (serverseitig am User gespeichert). `time` sind ganze
/// Sekunden und zugleich der Schlüssel zum Löschen.
struct ABSBookmark: Codable, Identifiable, Equatable {
    let libraryItemId: String
    let title: String
    let time: Double
    let createdAt: Double?

    var id: String { "\(libraryItemId)-\(time)" }
}

/// Ein Fortschritts-Eintrag aus /api/me. Wird lokal den Büchern zugeordnet,
/// damit die ganze Bibliotheksliste Indikatoren zeigen kann, ohne pro Buch
/// einen eigenen Request zu brauchen.
struct MediaProgressEntry: Decodable {
    let libraryItemId: String
    /// Nur bei Podcast-Fortschritt gesetzt — identifiziert die Episode.
    let episodeId: String?
    let currentTime: Double?
    let duration: Double?
    let progress: Double?
    let isFinished: Bool?
    let lastUpdate: Double?
}

/// Kompakte, view-freundliche Fortschrittsinfo für ein Buch. Codable, damit
/// sie zusammen mit der Bücherliste für den Offline-Zugriff zwischengespeichert
/// werden kann.
struct BookProgress: Equatable, Codable {
    let fraction: Double      // 0...1
    let isFinished: Bool
    let lastUpdate: Double    // ms seit 1970, für Sortierung "zuletzt gehört"
    /// Absolute Position in Sekunden — Fallback, um fraction lokal aus der
    /// Buchdauer nachzurechnen, wenn der Server sie nicht liefert (Multi-File-
    /// Bücher mit fehlender Server-Duration). Optional: alte Disk-Caches.
    var currentTime: Double? = nil

    var percentInt: Int { Int((fraction * 100).rounded()) }
    var isStarted: Bool { fraction > 0.001 && !isFinished }

    /// Restzeit-Text („noch 3 Std. 12 Min.") aus der Buchdauer — nil, wenn
    /// keine Dauer bekannt ist (dann Prozent als Fallback zeigen).
    func remainingText(bookDuration: Double?) -> String? {
        guard let bookDuration, bookDuration > 0 else { return nil }
        let listened = currentTime ?? fraction * bookDuration
        let remaining = max(0, bookDuration - listened)
        let totalMinutes = Int(remaining) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return String(localized: "\(hours) hr \(minutes) min left") }
        return String(localized: "\(minutes) min left")
    }
}

// MARK: - Bibliotheken

struct LibrariesResponse: Decodable {
    let libraries: [ABSLibrary]
}

struct ABSLibrary: Decodable, Identifiable {
    let id: String
    let name: String
    /// "book" | "podcast" — unterscheidet Hörbuch- von Podcast-Bibliotheken.
    /// Default nil → bestehende Memberwise-Init-Aufrufe (RSS/Local) bleiben gültig.
    var mediaType: String? = nil

    var isPodcast: Bool { mediaType == "podcast" }
}

// MARK: - Bücherliste (List-Endpoint)

struct LibraryItemsResponse: Decodable {
    let results: [LibraryItem]
}

struct LibraryItem: Codable, Identifiable {
    let id: String
    let media: LibraryItemMedia?
    let addedAt: Double?

    var title: String {
        media?.metadata?.title ?? String(localized: "Unknown Title")
    }

    var author: String? {
        media?.metadata?.authorName
    }
}

// MARK: - Buchdetails (Expanded-Endpoint, für den Player)

struct LibraryItemDetail: Codable, Identifiable {
    let id: String
    let media: LibraryItemMedia
    let userMediaProgress: MediaProgress?
}

struct LibraryItemMedia: Codable {
    let metadata: LibraryItemMetadata?
    let duration: Double?
    let chapters: [ABSChapter]?
    let tracks: [ABSAudioTrack]?
    /// Nur Podcast-Bibliotheken: die Folgen der Show (Detail-Endpoint).
    /// Default nil, damit bestehende Memberwise-Init-Aufrufe unverändert bauen.
    var episodes: [ABSPodcastEpisode]? = nil
}

struct LibraryItemMetadata: Codable {
    let title: String?
    let authorName: String?
    let narratorName: String?
    let seriesName: String?
    let genres: [String]?
    let publishedYear: LenientString?
    let description: String?
    /// Nur Podcasts: Feed-URL (für Quellen-übergreifende Dedup mit RSS).
    /// Default nil → bestehende Memberwise-Init-Aufrufe bleiben gültig.
    var feedUrl: String? = nil
}

/// Eine Podcast-Folge einer ABS-Show (`media.episodes[]` im Detail-Endpoint).
/// `audioTrack` ist der streambare Track (contentUrl relativ zum Server).
struct ABSPodcastEpisode: Codable, Identifiable {
    let id: String
    let title: String?
    let subtitle: String?
    let description: String?
    let publishedAt: Double?   // ms seit 1970
    let duration: Double?
    let index: Int?
    let season: String?
    let episode: String?
    let audioTrack: ABSAudioTrack?
}

/// Manche Audiobookshelf-Felder (z. B. publishedYear) liefern je nach
/// Server-Version mal einen String, mal eine Zahl. Dieser Wrapper nimmt
/// beides entgegen, statt bei einem Typ-Mismatch den ganzen Decode
/// scheitern zu lassen.
struct LenientString: Codable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            value = s
        } else if let i = try? container.decode(Int.self) {
            value = String(i)
        } else if let d = try? container.decode(Double.self) {
            value = String(Int(d))
        } else {
            value = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

struct ABSChapter: Codable, Identifiable, Equatable {
    let id: Int
    let start: Double
    let end: Double
    let title: String
}

struct ABSAudioTrack: Codable {
    let index: Int?
    let startOffset: Double?
    let duration: Double?
    let contentUrl: String
    /// File metadata (size in bytes) — used for the free-space check
    /// before a download starts.
    let metadata: ABSFileMetadata?
}

struct ABSFileMetadata: Codable {
    let size: Int64?
}

// MARK: - Fortschritt

struct MediaProgress: Codable {
    let currentTime: Double?
    let duration: Double?
    let progress: Double?
    let isFinished: Bool?
    /// ms seit 1970 — für den Geräte-Abgleich (neuerer Eintrag gewinnt).
    let lastUpdate: Double?
}
