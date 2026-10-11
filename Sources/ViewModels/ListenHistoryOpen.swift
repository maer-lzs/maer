// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// A tap on a row of the listening history: the row's target
/// (`ListenHistory.target`) opened through the one route of the source pages
/// (`PlayerSourceRouter`), the album of a server song asked of its server
/// first. What cannot open comes back with its reason for the page to say.
@MainActor
enum ListenHistoryOpen {
    enum Outcome: Equatable {
        case opened
        /// Leads nowhere on this device; the page says the reason.
        case unavailable(UnavailableReason)
        /// The server could not be asked; the page says the sentence.
        case failed(String)
        /// The tap ended before it was answered: nothing to say.
        case cancelled
    }

    static func open(_ entry: ListenHistory.Entry) async -> Outcome {
        let session = AppSession.shared
        let router = PlayerSourceRouter.shared
        let target = ListenHistory.target(of: entry, onShelf: session.libraryViewModel.entry(id: entry.id) != nil,
                                          sourceConfigured: session.provider(for: entry.id).isAvailable)
        switch target {
        case .book(let itemId):
            router.open(.book(itemId: itemId))
        case .catalogBook(let itemId):
            router.open(.catalogBook(itemId: itemId))
        case .catalogAlbum(let itemId):
            router.open(.catalogAlbum(itemId: itemId))
        case .serverSong(let itemId):
            do {
                guard let album = try await session.musicProvider(for: itemId).album(ofSong: itemId) else {
                    Logger.library.notice("HISTORY open song without album on the server")
                    return .unavailable(.notInLibrary)
                }
                router.open(.musicAlbum(album))
            } catch {
                if error.isCancellation { return .cancelled }
                Logger.library.notice("HISTORY open song album failed reason=\(FailureReason.of(error), privacy: .public)")
                return .failed(ErrorSentence.of(error))
            }
        case .unavailable(let reason):
            Logger.library.notice("HISTORY open unavailable reason=\(String(describing: reason), privacy: .public)")
            return .unavailable(reason)
        }
        return .opened
    }
}
