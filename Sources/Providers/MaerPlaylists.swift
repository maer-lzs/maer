// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog

/// Paket 1 (Auftrag 57a9380): Mär-Playlists — der ZWEITE Playlist-Typ neben
/// den Server-Playlists.
///
/// Warum es ihn braucht: Server-Playlists leben auf Navidrome/Jellyfin und
/// können nur Titel referenzieren, die dem Server gehören (`owns(itemId:)`).
/// Das Gate ist richtig und bleibt — ein Jamendo-Stück hat auf einer
/// Navidrome-Playlist keine Adresse. Für „gemischte" Listen braucht es also
/// einen eigenen Typ, der da lebt, wo alle Kennungen gelten: hier.
///
/// Datenform bewusst wie `PlayQueue`: eine Liste von KENNUNGEN, keine Dateien.
/// Jedes Gerät löst sie selbst auf und streamt selbst — es wird nichts
/// übertragen (Erweiterung 24132fa).
@MainActor
final class MaerPlaylists: ObservableObject {
    static let shared = MaerPlaylists()

    nonisolated struct Playlist: Codable, Identifiable, Hashable {
        var id: String
        var name: String
        /// Zeitstempel der letzten Änderung — Paket 2 führt je Liste
        /// zusammen, nicht je Eintrag (eine Eintrags-Zusammenführung könnte
        /// eine Löschung nicht von einem Fehlen unterscheiden).
        var updatedAt: Double
        var itemIds: [String]
    }

    @Published private(set) var playlists: [Playlist] = []

    /// Obergrenze über ALLE Mär-Playlists. Gemessen: die Kennungen sind
    /// 6–61 Zeichen lang (`rss:` ist die teuerste Klasse), im Schnitt ~32 Byte
    /// mit JSON-Hülle; der iCloud-Schlüssel-Wert-Speicher fasst 1 MB, also
    /// rechnerisch ~32.000 Einträge. 5.000 sind davon 16 % — genug Luft für
    /// die teure Klasse und für spätere Felder. Die Grenze gilt schon lokal,
    /// damit Paket 2 niemandem etwas wegnehmen muss.
    static let entryLimit = 5_000

    private let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("maer_playlists.json")

    private init() { load() }

    var totalEntries: Int { playlists.reduce(0) { $0 + $1.itemIds.count } }

    // MARK: - Lesen

    func playlist(id: String) -> Playlist? { playlists.first { $0.id == id } }

    /// Listen, in die dieses Element noch passt (für das Menü).
    func addable(itemId: String) -> [Playlist] {
        playlists.filter { !$0.itemIds.contains(itemId) }
    }

    // MARK: - Schreiben

    @discardableResult
    func create(name: String, itemIds: [String] = []) -> Playlist {
        let list = Playlist(id: UUID().uuidString,
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            updatedAt: Date().timeIntervalSince1970,
                            itemIds: itemIds.filter { PlayQueue.canEnqueue($0) })
        playlists.append(list)
        save()
        return list
    }

    /// Ergebnis des Hinzufügens — Regel 3: nichts scheitert still.
    enum AddOutcome: Equatable {
        case added
        /// Schon drin — kein Fehler, aber auch keine stille Wiederholung.
        case alreadyThere
        /// Die Obergrenze ist erreicht; die Zahl wandert in die Meldung.
        case limitReached(limit: Int)
        /// Der Typ gehört nicht in eine Liste (Radio: ein endloser Strom ist
        /// kein Listeneintrag — Entscheid F3, dieselbe Regel wie die
        /// Warteschlange, kein zweiter Gate-Begriff).
        case notQueueable
    }

    @discardableResult
    func add(itemId: String, to playlistId: String) -> AddOutcome {
        guard PlayQueue.canEnqueue(itemId) else { return .notQueueable }
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return .notQueueable }
        if playlists[index].itemIds.contains(itemId) { return .alreadyThere }
        guard totalEntries < Self.entryLimit else { return .limitReached(limit: Self.entryLimit) }
        playlists[index].itemIds.append(itemId)
        playlists[index].updatedAt = Date().timeIntervalSince1970
        save()
        return .added
    }

    /// Mehrere auf einmal (Album, Warteschlange sichern) — die Grenze zählt
    /// pro Eintrag, angehängt wird so viel wie passt, und der Aufrufer
    /// erfährt, wenn etwas nicht mehr hineinging.
    @discardableResult
    func add(itemIds: [String], to playlistId: String) -> AddOutcome {
        var outcome = AddOutcome.added
        for id in itemIds {
            let result = add(itemId: id, to: playlistId)
            if case .limitReached = result { outcome = result; break }
        }
        return outcome
    }

    func remove(itemId: String, from playlistId: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        playlists[index].itemIds.removeAll { $0 == itemId }
        playlists[index].updatedAt = Date().timeIntervalSince1970
        save()
    }

    func rename(playlistId: String, to name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        playlists[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        playlists[index].updatedAt = Date().timeIntervalSince1970
        save()
    }

    func delete(playlistId: String) {
        playlists.removeAll { $0.id == playlistId }
        save()
    }

    func move(playlistId: String, from source: IndexSet, to destination: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        var ids = playlists[index].itemIds
        let moved = source.map { ids[$0] }
        for i in source.sorted(by: >) { ids.remove(at: i) }
        let insertAt = min(max(0, destination - source.filter { $0 < destination }.count), ids.count)
        ids.insert(contentsOf: moved, at: insertAt)
        playlists[index].itemIds = ids
        playlists[index].updatedAt = Date().timeIntervalSince1970
        save()
    }

    // MARK: - Persistenz (PlayQueue-Muster)

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode([Playlist].self, from: data) else {
            // Beschädigte Datei wird NICHT still überschrieben (V2-Lehre).
            let backup = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            Logger.library.error("maer playlists undecodable — preserved as .corrupt")
            return
        }
        playlists = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
