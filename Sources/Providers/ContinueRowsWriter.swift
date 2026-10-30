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
    /// widget knows which snapshot is newer than the rows; when the rows
    /// changed, also the covers they name, and reloads the widget.
    static func write(_ rows: [WidgetSourceRow], passAtMs: Double) async {
        let changed = ContinueRows.load()?.rows != rows
        guard ContinueRows(rows: rows, passAtMs: passAtMs).save() else {
            Logger.library.notice("WIDGET rows not written count=\(rows.count, privacy: .public)")
            return
        }
        guard changed else { return }
        reload()
        let covered = rows.compactMap { row in row.cover.map { (id: row.itemId, name: $0) } }
        let wrote = await WidgetCoverWriter.write(covered, into: .continueRows) {
            Set(ContinueRows.load()?.rows.compactMap(\.cover) ?? [])
        }
        if wrote { reload() }
    }

    private static func reload() {
        WidgetCenter.shared.reloadTimelines(ofKind: "ContinueListeningWidget")
    }
}
