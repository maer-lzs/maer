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
    /// The books the rows hold; no rows or a failed read is no book.
    nonisolated static func books(rows: LibraryRowStore?) async -> [BookEntity] {
        guard let rows else { return [] }
        do {
            return books(from: try await rows.loadAll()?.items ?? [])
        } catch {
            Logger.library.error("SHORTCUT rows failed reason=\(String(describing: error), privacy: .public)")
            return []
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
            Logger.library.error("SHORTCUT rows unavailable reason=\(String(describing: error), privacy: .public)")
        }
        return await Self.books(rows: rows)
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
                "Drive mode in the \(.applicationName) app",
                "\(.applicationName) Fahrmodus",
                "Fahrmodus in der \(.applicationName)-App",
                "Fahrmodus der App \(.applicationName)"
            ],
            shortTitle: "Drive Mode",
            systemImageName: "car.fill"
        )
        AppShortcut(
            intent: ContinueListeningIntent(),
            // Every intent carries a form with the word "app": Siri hears
            // the bare name as the German word for "more", so people say
            // "in der Maer-App" or "von der App Maer", and those forms must
            // be registered or Siri takes the generic media intent instead
            // (measured on a device, 14.09.2026).
            phrases: [
                "Continue listening in \(.applicationName)",
                "Continue listening in the \(.applicationName) app",
                "Resume my audiobook in \(.applicationName)",
                "Resume my audiobook in the \(.applicationName) app",
                "Weiterhören in \(.applicationName)",
                "Weiterhören in der \(.applicationName)-App",
                "Weiterhören mit der App \(.applicationName)",
                "Höre mein Hörbuch in \(.applicationName) weiter",
                "Höre mein Hörbuch in der \(.applicationName)-App weiter"
            ],
            shortTitle: "Continue Listening",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PlayBookIntent(),
            phrases: [
                "Play \(\.$book) in \(.applicationName)",
                "Play \(\.$book) in the \(.applicationName) app",
                "Play \(\.$book) with the \(.applicationName) app",
                "Spiele \(\.$book) in \(.applicationName)",
                "Spiele \(\.$book) in der \(.applicationName)-App",
                "Spiele \(\.$book) mit der App \(.applicationName)",
                "Spiele \(\.$book) von der App \(.applicationName)",
                "Spiel \(\.$book) von der App \(.applicationName)",
                "Spiel \(\.$book) in der \(.applicationName)-App"
            ],
            shortTitle: "Play Audiobook",
            systemImageName: "book.fill"
        )
    }
}
