// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog

/// Mär playlists — the SECOND playlist type next to the server playlists.
///
/// A server playlist can only reference what the server owns (`owns(itemId:)`),
/// and that gate is correct: a catalogue track has no address on Navidrome. A
/// mixed list therefore needs its own type, living where every id is valid.
///
/// The data shape follows `PlayQueue` on purpose: a list of IDS, not files.
/// Every device resolves and streams them itself, so nothing is transferred.
@MainActor
final class MaerPlaylists: ObservableObject {
    static let shared = MaerPlaylists()

    nonisolated struct Playlist: Codable, Identifiable, Hashable {
        var id: String
        var name: String
        /// A version that LOST a merge and was kept instead of dropped. It
        /// stays on this device: pushing it would multiply the same rescue
        /// across every device on the next reconcile. Renaming it clears the
        /// mark — that is the user adopting it as a normal list.
        var isRescue: Bool = false
        /// Timestamp of the last change — the cross-device merge works per
        /// LIST, not per entry: an entry-level union cannot tell a deletion
        /// from a missing entry.
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
    /// deleted here returns from iCloud on the next reconcile.
    private static let tombstoneKey = "maerPlaylistTombstones"
    static var tombstones: [String: Double] {
        get { (UserDefaults.standard.dictionary(forKey: tombstoneKey) as? [String: Double]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: tombstoneKey) }
    }

    @Published private(set) var playlists: [Playlist] = []

    /// Upper bound across ALL Mär playlists. Measured: ids are 6–61 characters
    /// (`rss:` is the most expensive class), ~32 bytes each with JSON overhead;
    /// the iCloud key-value store holds 1 MB, so ~32,000 entries fit. 5,000 is
    /// 16 % of that — headroom for the expensive class and for later fields.
    /// The bound applies locally already, so the cross-device merge never has
    /// to take anything away.
    static let entryLimit = 5_000

    private let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("maer_playlists.json")

    private init() { load() }

    var totalEntries: Int { playlists.reduce(0) { $0 + $1.itemIds.count } }

    // MARK: - Reading

    func playlist(id: String) -> Playlist? { playlists.first { $0.id == id } }

    /// Lists this item still fits into (for the menu).
    func addable(itemId: String) -> [Playlist] {
        playlists.filter { !$0.itemIds.contains(itemId) }
    }

    // MARK: - Writing

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

    /// Outcome of adding — Regel 3: nothing fails silently.
    enum AddOutcome: Equatable {
        case added
        /// Already there — not an error, but not a silent repeat either.
        case alreadyThere
        /// The bound is reached; the number goes into the message.
        case limitReached(limit: Int)
        /// The type does not belong in a list — an endless stream is not a
        /// list entry. Same rule as the queue, no second gate concept.
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

    /// Several at once (album, saving the queue) — the bound counts per entry,
    /// as much is appended as fits, and the caller learns when something did
    /// not.
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
            // A corrupt file is NOT overwritten silently.
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
