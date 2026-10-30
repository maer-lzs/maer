// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The one way to continue listening: Siri, the quick action and the
/// widget's link through the library view, and the command of the widget's
/// play button, the round widget and the control from the app's process
/// without a view. All ask `ResumeTarget.pick` and find titles the same way.
extension PlayerCoordinator {
    enum ResumeCaller: String {
        case view
        case command
    }

    /// The title behind an id, the way the library view finds it: the
    /// loaded library list, then the session's stock (`known`, the view's
    /// router or the session itself). Never the server.
    static func resumeItem(forId id: String, entries: [LibraryEntry],
                           known: @MainActor (String) -> LibraryItem?) -> LibraryItem? {
        entries.first(where: { $0.id == id })?.item ?? known(id)
    }

    /// Continues listening and says what it did. The command runs without
    /// a view: on a cold start it first puts the library's stored rows into
    /// the list (the view's cache-first path, all rows or none) and waits
    /// for a podcast episode's index. It never waits for a load and never
    /// leaves a request behind; the view keeps waiting on `.waitForLibrary`.
    @discardableResult
    func resume(namedItemId: String?, by caller: ResumeCaller, library given: LibraryViewModel? = nil,
                lastPlayedId: String? = AppStorageKeys.lastPlayedItemIdValue) async -> ResumeTarget {
        let session = AppSession.shared
        let library = given ?? session.libraryViewModel
        if caller == .command, library.entries.isEmpty {
            await library.showCachedLibraryIfAvailable()
        }
        for id in [namedItemId, lastPlayedId].compactMap({ $0 }) where ItemNamespace.isPodcastEpisode(id) {
            await PodcastSubscriptions.shared.ensureLoaded()
        }
        let entries = library.entries
        let named = namedItemId.flatMap { Self.resumeItem(forId: $0, entries: entries, known: session.libraryItem) }
        let last = lastPlayedId.flatMap { Self.resumeItem(forId: $0, entries: entries, known: session.libraryItem) }
        let target = ResumeTarget.pick(namedItemId: namedItemId, namedItemKnown: named != nil,
                                       hasActivePlayer: viewModel != nil,
                                       lastPlayedId: lastPlayedId, lastPlayedKnown: last != nil,
                                       libraryLoading: caller == .view && library.isLoading)
        Logger.player.notice("RESUME by=\(caller.rawValue, privacy: .public) target=\(target.name, privacy: .public)")
        switch target {
        case .item:
            if let named { await open(item: named) }
        case .resumeActive:
            await viewModel?.playWithServerCheck()
        case .lastPlayed:
            if let last { await open(item: last) }
        case .waitForLibrary:
            break
        case .nothing(let missing):
            Logger.library.notice("RESUME request found no title what=\(missing, privacy: .public) by=\(caller.rawValue, privacy: .public)")
        }
        return target
    }
}
