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

/// Kompakte, view-freundliche Fortschrittsinfo für ein Buch.
struct BookProgress: Equatable {
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

struct LibraryItem: Decodable, Identifiable {
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

struct LibraryItemDetail: Decodable, Identifiable {
    let id: String
    let media: LibraryItemMedia
    let userMediaProgress: MediaProgress?
}

struct LibraryItemMedia: Decodable {
    let metadata: LibraryItemMetadata?
    let duration: Double?
    let chapters: [ABSChapter]?
    let tracks: [ABSAudioTrack]?
}

struct LibraryItemMetadata: Decodable {
    let title: String?
    let authorName: String?
    let description: String?
}

struct ABSChapter: Decodable, Identifiable, Equatable {
    let id: Int
    let start: Double
    let end: Double
    let title: String
}

struct ABSAudioTrack: Decodable {
    let index: Int?
    let startOffset: Double?
    let duration: Double?
    let contentUrl: String
}

// MARK: - Fortschritt

struct MediaProgress: Decodable {
    let currentTime: Double?
    let duration: Double?
    let progress: Double?
    let isFinished: Bool?
}
