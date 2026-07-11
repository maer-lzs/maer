import AppIntents
import Foundation

/// "Weiterhören": öffnet die App und setzt das zuletzt gehörte Buch fort —
/// derselbe Pfad wie die Home-Screen-Quick-Action (Pending-Flag +
/// Notification, ausgeführt von der Bibliothek).
struct ContinueListeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Listening"
    static let description = IntentDescription("Resumes the last played audiobook.")
    /// Robusteste Variante: App in den Vordergrund holen und dort starten
    /// (Audio-Start aus dem Hintergrund wäre fehleranfälliger).
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ResumeRequest.pending = true
        NotificationCenter.default.post(name: .resumeLastBookRequested, object: nil)
        return .result()
    }
}

// MARK: - "Spiele [Buch]"

/// Buch-Entität für den Siri-Parameter — gespeist aus dem Bibliotheks-Disk-
/// Cache (liegt als JSON in Documents), damit die Suche auch funktioniert,
/// wenn die App nicht läuft.
struct BookEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Audiobook"
    static let defaultQuery = BookQuery()

    let id: String
    let title: String
    let author: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: author.map { "\($0)" }
        )
    }
}

struct BookQuery: EntityStringQuery {
    /// Minimal-Decoder für library_cache.json (unbekannte Felder ignoriert
    /// JSONDecoder) — kein Zugriff auf die MainActor-ViewModels nötig.
    private nonisolated struct CachedLibrary: Decodable {
        struct Item: Decodable {
            struct Media: Decodable {
                struct Meta: Decodable {
                    let title: String?
                    let authorName: String?
                }
                let metadata: Meta?
            }
            let id: String
            let media: Media?
        }
        let items: [Item]
    }

    private func allBooks() -> [BookEntity] {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("library_cache.json")
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(CachedLibrary.self, from: data) else { return [] }
        return cache.items.compactMap { item in
            guard let title = item.media?.metadata?.title else { return nil }
            return BookEntity(id: item.id, title: title, author: item.media?.metadata?.authorName)
        }
    }

    func entities(for identifiers: [String]) async throws -> [BookEntity] {
        let books = allBooks()
        return identifiers.compactMap { id in books.first { $0.id == id } }
    }

    func entities(matching string: String) async throws -> [BookEntity] {
        allBooks().filter { $0.title.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [BookEntity] {
        Array(allBooks().prefix(12))
    }
}

/// "Spiele [Buch]": öffnet die App und startet gezielt dieses Buch.
struct PlayBookIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Audiobook"
    static let description = IntentDescription("Plays a specific audiobook from your library.")
    static let openAppWhenRun = true

    @Parameter(title: "Book")
    var book: BookEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        ResumeRequest.pendingItemId = book.id
        NotificationCenter.default.post(name: .resumeLastBookRequested, object: nil)
        return .result()
    }
}

struct MaerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ContinueListeningIntent(),
            phrases: [
                "Continue listening in \(.applicationName)",
                "Resume my audiobook in \(.applicationName)",
                "Weiterhören in \(.applicationName)",
                "Höre mein Hörbuch in \(.applicationName) weiter"
            ],
            shortTitle: "Continue Listening",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PlayBookIntent(),
            phrases: [
                "Play \(\.$book) in \(.applicationName)",
                "Spiele \(\.$book) in \(.applicationName)"
            ],
            shortTitle: "Play Audiobook",
            systemImageName: "book.fill"
        )
    }
}
