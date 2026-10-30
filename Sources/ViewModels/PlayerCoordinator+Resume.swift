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

    /// A request to continue found no title: said like a search hit that
    /// no longer resolves, never a silent tap. The one sentence for the
    /// view and for the widget's command; the door writes the line.
    func sayNothingToResume() {
        Haptics.tap()
        sayOpenFailure(String(localized: "Audiobook could not be loaded."), cause: .unknown, title: nil)
    }

    /// Continues listening and says what it did. The command runs without
    /// a view: on a cold start it first puts the library's stored rows into
    /// the list (the view's cache-first path, all rows or none). It never
    /// waits for a load and never leaves a request behind; the view keeps
    /// waiting on `.waitForLibrary`.
    ///
    /// Every title resolves the way the app's own restore resolves it
    /// (`resolveStandbyItem`: the list, the session's resolver with a detail
    /// fetch from the title's server, the feed), so a song or a Jellyfin
    /// title the session's memory does not hold after a cold start is still
    /// found. A title Siri or a widget row named is that title or nothing,
    /// never the show's newest episode beside it, like the play on a foreign
    /// claim. The last played title is asked only when it is the question,
    /// with no title named and no player open, and without the neighbour
    /// too: the door plays what it finds, and only the restore at start,
    /// which does not play, may take one (`standbyTail`). A title that left
    /// its feed is nothing found. `resolve` stands in for the chain in a
    /// witness; its third argument says whether the neighbour may be taken.
    @discardableResult
    func resume(namedItemId: String?, by caller: ResumeCaller, library given: LibraryViewModel? = nil,
                lastPlayedId: String? = AppStorageKeys.lastPlayedItemIdValue,
                resolve resolver: (@MainActor (String, [LibraryEntry], Bool) async -> LibraryItem?)? = nil) async -> ResumeTarget {
        let session = AppSession.shared
        let library = given ?? session.libraryViewModel
        if caller == .command, library.entries.isEmpty {
            await library.showCachedLibraryIfAvailable()
        }
        let resolve = resolver ?? { id, entries, allowsShowNewest in
            await self.resolveStandbyItem(id, entries: entries, allowsShowNewest: allowsShowNewest)
        }
        let entries = library.entries
        var named: LibraryItem?
        if let namedItemId { named = await resolve(namedItemId, entries, false) }
        var last: LibraryItem?
        if namedItemId == nil, viewModel == nil, let lastPlayedId { last = await resolve(lastPlayedId, entries, false) }
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
