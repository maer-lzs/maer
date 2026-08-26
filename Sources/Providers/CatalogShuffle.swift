// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Zufällig abspielen an einer Musik-Katalog-Reihe oder einem Fach — und zwar
/// aus dem GANZEN Fach, nicht aus den zwölf sichtbaren Kacheln. Ein Fach
/// fasst mehrere tausend Aufnahmen; würfelte man unter der Vorschau, hörte
/// man immer dieselben.
///
/// Zwei Messungen bestimmen die Form:
///  * archive.org kann `sort=random`, aber **nicht pro Aufruf**: drei schnelle
///    Wiederholungen liefern identische Titel (Zwischenspeicher), erst nach
///    einigen Minuten andere. Verschiedene SEITEN liefern dagegen sofort
///    verschiedene Titel. Deshalb: Zufallssortierung UND zufällige Seite —
///    dann ist jeder Tipp verschieden, nicht nur jeder zehnte.
///  * Jamendo kennt `order=random` NICHT (`status=failed`), dort wird über
///    einen zufälligen `offset` gezogen. Ehrlich benannt statt behauptet.
///
/// Die Warteschlange wird NIE überschrieben: der erste Titel spielt sofort,
/// der Rest wird angehängt. Ein Fehltipp darf keine Session zerstören.
@MainActor
enum CatalogShuffle {
    /// How many titles one shuffle pulls (the first plays, the rest queue).
    static let batch = 12

    /// Deepest page the draw may reach — the whole stock, not a window: this
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

    /// Draw from Jamendo (no random order there — random offset instead).
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

    /// First one plays, the rest are APPENDED — never a replaced queue.
    private static func start(_ items: [LibraryItem], coordinator: PlayerCoordinator) async {
        guard let first = items.first else { return }
        for item in items.dropFirst() where PlayQueue.canEnqueue(item.id) {
            PlayQueue.shared.playLast(item.id)
        }
        await coordinator.open(item: first)
    }
}

/// M1-KORREKTUR: der Typ ist DATENGETRIEBEN, nicht sammlungsweise.
/// Gemessen an echten Einträgen: Netlabels 4–79 Spuren, Schallplatten-Jazz 36,
/// Klassik 1. Eine Regel je Fläche wäre also falsch — die Antwort entscheidet.
///
/// Beim Tap wird die Detail-Antwort ohnehin geholt (ohne sie gibt es keine
/// Abspieladresse), und genau sie trägt die Spurenzahl:
///  * **eine Spur → sofort abspielen** (das M1-Gefühl bleibt: der Dreiminüter
///    startet),
///  * **mehrere Spuren → Albumseite** mit Titelliste; ein Tipp dort spielt
///    DIESE Spur (Offset-Weg wie bei den OTR-Bündeln).
///
/// Kein Raten, kein Sammlungs-Sonderfall, kein zweiter Ladeweg.
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
