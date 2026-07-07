import Foundation

// MARK: - Authorisierung / Nutzer

struct ABSUser: Decodable {
    let id: String
    let username: String
}

/// Antwort von /api/me — enthält alle Fortschritts-Einträge des Nutzers.
struct MeResponse: Decodable {
    let mediaProgress: [MediaProgressEntry]?
}

/// Ein Fortschritts-Eintrag aus /api/me. Wird lokal den Büchern zugeordnet,
/// damit die ganze Bibliotheksliste Indikatoren zeigen kann, ohne pro Buch
/// einen eigenen Request zu brauchen.
struct MediaProgressEntry: Decodable {
    let libraryItemId: String
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

    var percentInt: Int { Int((fraction * 100).rounded()) }
    var isStarted: Bool { fraction > 0.001 && !isFinished }
}

// MARK: - Bibliotheken

struct LibrariesResponse: Decodable {
    let libraries: [ABSLibrary]
}

struct ABSLibrary: Decodable, Identifiable {
    let id: String
    let name: String
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
        media?.metadata?.title ?? "Unbekannter Titel"
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
}

struct LibraryItemMetadata: Codable {
    let title: String?
    let authorName: String?
    let narratorName: String?
    let seriesName: String?
    let genres: [String]?
    let publishedYear: LenientString?
    let description: String?
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
