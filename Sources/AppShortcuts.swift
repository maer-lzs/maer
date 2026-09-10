// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import AppIntents
import Foundation
import OSLog

/// "Continue listening": opens the app and resumes the last played book. The
/// same path as the home-screen quick action (pending flag + notification,
/// carried out by the library).
struct ContinueListeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Listening"
    static let description = IntentDescription("Resumes the last played audiobook.")
    /// Most robust variant: bring the app to the foreground and start there
    /// (starting audio from the background would be more error-prone).
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ResumeRequest.pending = true
        NotificationCenter.default.post(name: .resumeLastBookRequested, object: nil)
        return .result()
    }
}

// MARK: - "Play [book]"

/// Book entity for the Siri parameter. Fed from the library rows, which
/// hold the library since the document was poured into them; the document
/// in Documents stays the reader of last resort for a device that has not
/// migrated yet.
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
    /// Minimal decoder for library_cache.json (JSONDecoder ignores unknown
    /// fields). No access to the MainActor view models needed.
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

    nonisolated static var documentURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("library_cache.json")
    }

    /// The rows first, the document only when the rows hold nothing. After
    /// the first start on a build with rows the document is set aside and
    /// gone, and a query that read only the document found no book (a
    /// reader the seam did not know). The document read leaves with 3.1.
    nonisolated static func books(rows: LibraryRowStore?, fallback: URL) async -> [BookEntity] {
        if let rows {
            do {
                if let cache = try await rows.loadAll(), !cache.items.isEmpty {
                    return books(from: cache.items)
                }
            } catch {
                Logger.library.error("SHORTCUT rows failed reason=\(String(describing: error), privacy: .public); reading the document")
            }
        }
        // tragbar, weil ein fehlendes Dokument nach dem Umzug der Normalfall ist; die Zeilen wurden davor gefragt
        guard let data = try? Data(contentsOf: fallback),
              let cache = try? JSONDecoder().decode(CachedLibrary.self, from: data) else { return [] }
        return cache.items.compactMap { item in
            guard let title = item.media?.metadata?.title else { return nil }
            return BookEntity(id: item.id, title: title, author: item.media?.metadata?.authorName)
        }
    }

    /// The entities out of the rows' items: a book needs a title.
    nonisolated static func books(from items: [LibraryItem]) -> [BookEntity] {
        items.compactMap { item in
            guard let title = item.media?.metadata?.title else { return nil }
            return BookEntity(id: item.id, title: title, author: item.author)
        }
    }

    private func allBooks() async -> [BookEntity] {
        var rows: LibraryRowStore?
        do {
            rows = try await MaerDatabase.libraryRows()
        } catch {
            Logger.library.error("SHORTCUT rows unavailable reason=\(String(describing: error), privacy: .public); reading the document")
        }
        return await Self.books(rows: rows, fallback: Self.documentURL)
    }

    func entities(for identifiers: [String]) async throws -> [BookEntity] {
        let books = await allBooks()
        return identifiers.compactMap { id in books.first { $0.id == id } }
    }

    func entities(matching string: String) async throws -> [BookEntity] {
        await allBooks().filter { $0.title.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [BookEntity] {
        Array(await allBooks().prefix(12))
    }
}

/// "Play [book]": opens the app and starts this specific book.
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

struct DriveModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Drive Mode"
    static let description = IntentDescription("Opens the big-button drive layout.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        DriveModeController.shared.enter()
        return .result()
    }
}

struct MaerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DriveModeIntent(),
            phrases: [
                "\(.applicationName) drive mode",
                "\(.applicationName) Fahrmodus"
            ],
            shortTitle: "Drive Mode",
            systemImageName: "car.fill"
        )
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
