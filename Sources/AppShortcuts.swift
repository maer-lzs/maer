// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import AppIntents
import Foundation

/// "Continue listening": opens the app and resumes the last played book — the
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

/// Book entity for the Siri parameter — fed from the library disk cache (JSON
/// in Documents) so search works even when the app is not running.
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
    /// fields) — no access to the MainActor view models needed.
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
