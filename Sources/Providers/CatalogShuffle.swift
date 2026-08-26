// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Shuffle play on a music catalog row or a shelf, drawing from the WHOLE
/// shelf rather than from the twelve visible tiles. A shelf holds several
/// thousand recordings; drawing from the preview would always yield the same
/// ones.
///
/// Two measurements decide the shape:
///  * archive.org supports `sort=random`, but **not per call**: three quick
///    repetitions return identical titles (caching), different ones only
///    after some minutes. Different PAGES return different titles at once.
///    Hence random sort AND a random page, so every tap differs instead of
///    every tenth.
///  * Jamendo does NOT know `order=random` (`status=failed`), so there the
///    draw runs over a random `offset`. Named honestly rather than claimed.
///
/// The queue is NEVER overwritten: the first track plays at once, the rest is
/// appended. A mistaken tap must not destroy a session.
@MainActor
enum CatalogShuffle {
    /// How many titles one shuffle pulls (the first plays, the rest queue).
    static let batch = 12

    /// Deepest page the draw may reach. The whole stock, not a window: this
    /// is the "anything at all" gesture, in deliberate contrast to the row's
    /// daily rotation inside the top tenth.
    static func maxPage(total: Int, rows: Int) -> Int {
        guard total > rows, rows > 0 else { return 1 }
        return max(1, total / rows)
    }

    /// Draw from an archive.org area and start playing.
    static func play(area: ArchiveMusicArea, coordinator: PlayerCoordinator) async {
        let page = Int.random(in: 1...maxPage(total: area.measuredTotal, rows: batch))
        do {
            let docs = try await ArchiveOrgClient.popular(
                query: area.query, rows: batch, page: page, sort: "random")
            let items = docs.filter { FreeCatalog.isCuratedArchiveDoc($0) }
                .compactMap { FreeCatalogProvider.shared.remember(popular: $0) }
            Logger.library.notice("SHUFFLE area=\(area.key, privacy: .public) page=\(page) got=\(items.count)")
            await start(items, coordinator: coordinator)
        } catch {
            Logger.library.error("SHUFFLE area=\(area.key, privacy: .public) FAILED: \(String(describing: error), privacy: .public)")
        }
    }

    /// Draw from Jamendo (no random order there. Random offset instead).
    static func playJamendo(tags: [String] = [], coordinator: PlayerCoordinator) async {
        let offset = Int.random(in: 0..<600)
        do {
            let tracks = try await JamendoClient.popularTracks(limit: batch, tags: tags, offset: offset)
            let items = tracks.compactMap { FreeCatalogProvider.shared.remember(track: $0) }
            Logger.library.notice("SHUFFLE jamendo offset=\(offset) got=\(items.count)")
            await start(items, coordinator: coordinator)
        } catch {
            Logger.library.error("SHUFFLE jamendo FAILED: \(String(describing: error), privacy: .public)")
        }
    }

    /// First one plays, the rest are APPENDED. Never a replaced queue.
    private static func start(_ items: [LibraryItem], coordinator: PlayerCoordinator) async {
        guard let first = items.first else { return }
        for item in items.dropFirst() where PlayQueue.canEnqueue(item.id) {
            PlayQueue.shared.playLast(item.id)
        }
        await coordinator.open(item: first)
    }
}

/// The form is DATA-DRIVEN, not decided per collection. Measured on real
/// entries: netlabels 4 to 79 tracks, shellac jazz 36, classical 1. A rule
/// per surface would therefore be wrong. The answer decides.
///
/// The detail answer is fetched on tap anyway (without it there is no
/// playback address), and it carries the track count:
///  * **one track → play at once**, so a three-minute piece just starts,
///  * **several tracks → album page** with a track list; a tap there plays
///    THAT track, over the same offset path as the OTR bundles.
///
/// No guessing, no per-collection special case, no second load path.
@MainActor
enum CatalogTap {
    static func open(item: LibraryItem,
                     coordinator: PlayerCoordinator,
                     pushMusicRoute: @MainActor (MusicRoute) -> Void) async {
        let count = (try? await FreeCatalogProvider.shared.fetchItemDetail(itemId: item.id))?
            .media.tracks?.count ?? 1
        if count > 1 {
            pushMusicRoute(.catalogAlbum(item.id))
        } else {
            await coordinator.open(item: item)
        }
    }
}
