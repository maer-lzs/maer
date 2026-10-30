// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog
import WidgetKit

/// The one writer of the rows of the large and medium "Continue"
/// (`ContinueRows`). The home page hands it what one pass knows; the rows
/// come from `ContinueBySource.rows`, the covers go to the store
/// `.continueRows`. The player never writes the rows.
enum ContinueRowsWriter {
    /// What one pass of the home page knows of a title, read where the
    /// home page reads it: the library entry of a book, the episode's or
    /// album's server progress, the station of a radio row, and this
    /// device's mark.
    static func card(for id: String, entry: LibraryEntry?, item: LibraryItem?, station: RadioStation?,
                     serverProgress: BookProgress?) -> ContinueBySource.Card? {
        let markedForm = ListeningStore.startedForm(id)
        let symbol = MediaFamily.placeholderSymbol(for: id, markedForm: markedForm)
        if let station {
            return ContinueBySource.Card(title: station.name, subtitle: nil, kindSymbol: symbol,
                                         markedForm: nil, isLive: true)
        }
        guard let item = entry?.item ?? item else { return nil }
        let duration = item.media?.duration
        let local = ListeningStore.mark(id).map {
            BookProgress.fromDeviceMark(position: $0.position, updatedAtMs: $0.updatedAtMs,
                                        markedDuration: $0.duration, itemDuration: duration, tail: 0)
        }
        return ContinueBySource.Card(title: item.title, subtitle: item.author, kindSymbol: symbol,
                                     markedForm: markedForm, isLive: false,
                                     local: local, server: entry?.progress ?? serverProgress, duration: duration)
    }

    /// Writes the rows with the moment of the pass, every pass, so the
    /// widget knows which title was heard after it. The widget reloads when
    /// the rows changed, or when the new moment leaves out the title of
    /// the player's snapshot that the earlier one let in
    /// (`WidgetRows.passMovesTitle`); covers only for changed rows.
    static func write(_ rows: [WidgetSourceRow], passAtMs: Double) async {
        let previous = ContinueRows.load()
        let changed = previous?.rows != rows
        guard ContinueRows(rows: rows, passAtMs: passAtMs).save() else {
            Logger.library.notice("WIDGET rows not written count=\(rows.count, privacy: .public)")
            return
        }
        guard changed else {
            if WidgetRows.passMovesTitle(oldPassAtMs: previous?.passAtMs, newPassAtMs: passAtMs,
                                         snapshot: WidgetSnapshot.load()) {
                reload()
            }
            return
        }
        reload()
        let covered = rows.compactMap { row in row.cover.map { (id: row.itemId, name: $0) } }
        let wrote = await WidgetCoverWriter.write(covered, into: .continueRows) {
            Set(ContinueRows.load()?.rows.compactMap(\.cover) ?? [])
        }
        if wrote { reload() }
    }

    /// A server signed out: the app shows the welcome page and the home
    /// page does not compute, so the rows of its last pass would stand.
    /// They go, with the moment now, so a snapshot heard before stays out
    /// too; the next pass writes anew.
    static func forget() async {
        await write([], passAtMs: Date().timeIntervalSince1970 * 1000)
    }

    /// A source switched or another device's choices adopted: a home pass
    /// follows only if the library changes, so the rows are cut here to the
    /// titles that still stand on the home page (`ContinueBySource.keepingStanding`).
    static func keepStanding(_ sourceRead: (String) -> Bool) async {
        let kept = ContinueBySource.keepingStanding(ContinueRows.load(), snapshotItemId: WidgetSnapshot.load()?.itemId,
                                                    nowMs: Date().timeIntervalSince1970 * 1000,
                                                    sourceRead: sourceRead)
        await write(kept.rows, passAtMs: kept.passAtMs)
    }

    private static func reload() {
        WidgetCenter.shared.reloadTimelines(ofKind: "ContinueListeningWidget")
    }
}
