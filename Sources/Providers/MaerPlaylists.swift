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
        /// A version that LOST a merge and was kept instead of dropped. It
        /// stays on this device: pushing it would multiply the same rescue
        /// across every device on the next reconcile (`ff1263c`). Renaming it
        /// clears the mark — that is the user adopting it as a normal list.
        var isRescue: Bool = false
        /// Zeitstempel der letzten Änderung — Paket 2 führt je Liste
        /// zusammen, nicht je Eintrag (eine Eintrags-Zusammenführung könnte
        /// eine Löschung nicht von einem Fehlen unterscheiden).
        var updatedAt: Double
        var itemIds: [String]

        // Tolerant decoding: files written before the rescue mark existed have
        // no such field, and a missing field must not fail the whole store.
        enum CodingKeys: String, CodingKey { case id, name, isRescue, updatedAt, itemIds }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            isRescue = (try? c.decode(Bool.self, forKey: .isRescue)) ?? false
            updatedAt = try c.decode(Double.self, forKey: .updatedAt)
            itemIds = try c.decode([String].self, forKey: .itemIds)
        }
        init(id: String, name: String, isRescue: Bool = false, updatedAt: Double, itemIds: [String]) {
            self.id = id
            self.name = name
            self.isRescue = isRescue
            self.updatedAt = updatedAt
            self.itemIds = itemIds
        }
    }

    /// Deleted lists with the moment of deletion — without this mark a list
    /// deleted here returns from iCloud on the next reconcile. Kept small: the
    /// mark is dropped once no device can still carry an older version (30
    /// days, the same order of magnitude as the podcast tombstones).
    private static let tombstoneKey = "maerPlaylistTombstones"
    static var tombstones: [String: Double] {
        get { (UserDefaults.standard.dictionary(forKey: tombstoneKey) as? [String: Double]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: tombstoneKey) }
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
        // Naming a rescue copy is the user adopting it — from here on it is an
        // ordinary list and travels with the others.
        playlists[index].isRescue = false
        playlists[index].updatedAt = Date().timeIntervalSince1970
        save()
    }

    func delete(playlistId: String) {
        playlists.removeAll { $0.id == playlistId }
        // The deletion needs to be a FACT, not the absence of one — otherwise
        // the next reconcile hands the list back.
        var marks = Self.tombstones
        marks[playlistId] = Date().timeIntervalSince1970
        Self.tombstones = marks
        save()
    }

    /// Adopt the state a merge produced. Rescue copies are appended, never
    /// pushed — see `MaerPlaylistMerge`.
    func apply(merged: [String: MaerPlaylistMerge.Entry],
               rescued: [MaerPlaylistMerge.Entry],
               tombstones marks: [String: Double],
               rescueName: (MaerPlaylistMerge.Entry) -> String) {
        var next = playlists.filter { $0.isRescue }
        for (id, entry) in merged {
            next.append(Playlist(id: id, name: entry.name,
                                 updatedAt: entry.updatedAt, itemIds: entry.itemIds))
        }
        let existing = next.map(\.itemIds)
        for candidate in rescued where MaerPlaylistMerge.needsRescue(candidate, existing: existing) {
            next.append(Playlist(id: UUID().uuidString, name: rescueName(candidate),
                                 isRescue: true, updatedAt: candidate.updatedAt,
                                 itemIds: candidate.itemIds))
        }
        Self.tombstones = marks
        playlists = next.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
    }

    /// Everything that may travel — rescue copies stay here.
    var syncable: [Playlist] { playlists.filter { !$0.isRescue } }

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
