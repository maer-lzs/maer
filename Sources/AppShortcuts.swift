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

// MARK: - "Start [routine]"

/// A routine for the Siri parameter: a list of this device with a rule.
struct RoutineEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Routine"
    static let defaultQuery = RoutineQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct RoutineQuery: EntityStringQuery {
    /// The routines among the lists, in the lists' order; a list without a
    /// rule is no routine and is not offered.
    nonisolated static func routines(from lists: [MaerPlaylists.Playlist]) -> [RoutineEntity] {
        lists.filter(\.isRoutine).map { RoutineEntity(id: $0.id, name: $0.name) }
    }

    @MainActor
    private func allRoutines() -> [RoutineEntity] {
        Self.routines(from: MaerPlaylists.shared.playlists)
    }

    func entities(for identifiers: [String]) async throws -> [RoutineEntity] {
        let routines = await allRoutines()
        return identifiers.compactMap { id in routines.first { $0.id == id } }
    }

    func entities(matching string: String) async throws -> [RoutineEntity] {
        await allRoutines().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [RoutineEntity] {
        await allRoutines()
    }
}

/// "Start [routine]": opens the app and starts this routine, the same
/// start as its card on Start.
struct PlayRoutineIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Routine"
    static let description = IntentDescription("Starts one of your routines.")
    static let openAppWhenRun = true

    @Parameter(title: "Routine")
    var routine: RoutineEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        // The newest request wins: an older one still waiting gives way,
        // and its line says which.
        if let standing = ResumeRequest.standing(routineId: ResumeRequest.pendingRoutineId, pending: ResumeRequest.pending,
                                                 itemId: ResumeRequest.pendingItemId) {
            Logger.library.notice("ROUTINE request \(routine.id, privacy: .public) replaces a waiting request: \(standing, privacy: .public)")
        }
        ResumeRequest.pending = false
        ResumeRequest.pendingItemId = nil
        ResumeRequest.pendingRoutineId = routine.id
        NotificationCenter.default.post(name: .resumeLastBookRequested, object: nil)
        return .result()
    }
}

extension MaerPlaylists {
    /// The shortcuts learn the routines anew: their phrases name them.
    static let refreshShortcuts: @MainActor () -> Void = { MaerShortcuts.updateAppShortcutParameters() }
}

struct DriveModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Drive Mode"
    static let description = IntentDescription("Opens the big-button drive layout.")
    static let openAppWhenRun = true
    /// Not offered in Shortcuts while drive mode's gate is closed.
    static var isDiscoverable: Bool { DriveModeGate.isOpen }

    @MainActor
    func perform() async throws -> some IntentResult {
        DriveModeController.shared.enter()
        return .result()
    }
}

struct MaerShortcuts: AppShortcutsProvider {
    // Drive mode has no phrase here while its gate is closed
    // (`DriveModeGate`); the builder takes no condition but `#available`.
    static var appShortcuts: [AppShortcut] {
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
        AppShortcut(
            intent: PlayRoutineIntent(),
            phrases: [
                "Start \(\.$routine) in \(.applicationName)",
                "Start \(\.$routine) in the \(.applicationName) app",
                "Start \(\.$routine) with the \(.applicationName) app",
                "Starte \(\.$routine) in \(.applicationName)",
                "Starte \(\.$routine) in der \(.applicationName)-App",
                "Starte \(\.$routine) mit der App \(.applicationName)",
                "Starte \(\.$routine) von der App \(.applicationName)"
            ],
            shortTitle: "Start Routine",
            systemImageName: "music.note.list"
        )
    }
}
