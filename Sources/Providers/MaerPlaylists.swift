// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog

/// Mär playlists. The SECOND playlist type next to the server playlists.
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
        /// mark. That is the user adopting it as a normal list.
        var isRescue: Bool = false
        /// Timestamp of the last change. The cross-device merge works per
        /// LIST, not per entry: an entry-level union cannot tell a deletion
        /// from a missing entry.
        var updatedAt: Double
        var itemIds: [String]
        /// Title snapshots per entry id, the first generation of what an
        /// entry carries. Kept beside `snapshots` for devices and blobs that
        /// speak only titles. See `MaerPlaylistMerge.Entry.titles`.
        var titles: [String: String] = [:]
        /// What each entry carries when it travels (`CarriedItem`: title,
        /// subtitle, duration, public cover, source). The seam `SyncCarried`
        /// takes it on adding and resolves it on the other device.
        var snapshots: [String: CarriedItem] = [:]
        /// The name's own clock, set on rename. See
        /// `MaerPlaylistMerge.Entry.nameUpdatedAt` for why the list clock
        /// cannot answer whose name is newer.
        var nameUpdatedAt: Double?
        /// Why a rescue copy exists, for the row under its name. Local only.
        var rescueReason: String?
        /// Entries removed from this list, with the moment of removal. The
        /// merge works per entry, and a removal must be a fact that
        /// travels, or the title returns from the other device. See
        /// `MaerPlaylistMerge.Entry.removed`.
        var removed: [String: Double] = [:]
        /// The moment each entry was added; the witness that tells a re-add
        /// from a removal. See `MaerPlaylistMerge.Entry.added`.
        var added: [String: Double] = [:]

        // Tolerant decoding: files written before the rescue mark existed have
        // no such field, and a missing field must not fail the whole store.
        enum CodingKeys: String, CodingKey {
            case id, name, isRescue, updatedAt, itemIds, titles, snapshots, nameUpdatedAt, rescueReason, removed, added
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            isRescue = (try? c.decode(Bool.self, forKey: .isRescue)) ?? false
            updatedAt = try c.decode(Double.self, forKey: .updatedAt)
            itemIds = try c.decode([String].self, forKey: .itemIds)
            titles = (try? c.decode([String: String].self, forKey: .titles)) ?? [:]
            snapshots = (try? c.decode([String: CarriedItem].self, forKey: .snapshots)) ?? [:]
            nameUpdatedAt = try? c.decode(Double.self, forKey: .nameUpdatedAt)
            rescueReason = try? c.decode(String.self, forKey: .rescueReason)
            // bearable, because a missing field is a file from before the field
            removed = (try? c.decode([String: Double].self, forKey: .removed)) ?? [:]
            // bearable, because a missing field is a file from before the field
            added = (try? c.decode([String: Double].self, forKey: .added)) ?? [:]
        }
        init(id: String, name: String, isRescue: Bool = false, updatedAt: Double,
             itemIds: [String], titles: [String: String] = [:], snapshots: [String: CarriedItem] = [:],
             nameUpdatedAt: Double? = nil, rescueReason: String? = nil,
             removed: [String: Double] = [:], added: [String: Double] = [:]) {
            self.id = id
            self.name = name
            self.isRescue = isRescue
            self.updatedAt = updatedAt
            self.itemIds = itemIds
            self.titles = titles
            self.snapshots = snapshots
            self.nameUpdatedAt = nameUpdatedAt
            self.rescueReason = rescueReason
            self.removed = removed
            self.added = added
        }

        /// What an entry carries: the snapshot, or the first-generation
        /// title alone when only that travelled.
        func carried(for itemId: String) -> CarriedItem? {
            snapshots[itemId] ?? titles[itemId].map { CarriedItem(id: itemId, title: $0) }
        }
    }

    /// Deleted lists with the moment of deletion. Without this mark a list
    /// deleted here returns from iCloud on the next reconcile.
    private static let tombstoneKey = "maerPlaylistTombstones"
    static var tombstones: [String: Double] {
        get { (AppStorageKeys.dictionary(tombstoneKey) as? [String: Double]) ?? [:] }
        set { AppStorageKeys.set(newValue, for: tombstoneKey) }
    }

    @Published private(set) var playlists: [Playlist] = []

    /// Told after every save, so the runner carries a local change to the
    /// far side without waiting for the next start. Set by the runner.
    var changed: (@MainActor () -> Void)?

    /// Upper bound across ALL Mär playlists. Measured: ids are 6–61 characters
    /// (`rss:` is the most expensive class), ~32 bytes each with JSON overhead;
    /// the iCloud key-value store holds 1 MB, so ~32,000 entries fit. 5,000 is
    /// 16 % of that. Headroom for the expensive class and for later fields.
    /// The bound applies locally already, so the cross-device merge never has
    /// to take anything away.
    static let entryLimit = 5_000

    /// The lists live as rows (one per list, `maer_playlist`). The document
    /// in Documents is read only when the rows hold nothing, poured into
    /// them once and set aside.
    private let database: MaerDatabase
    private let ablage: Ablage
    private let documentName = "maer_playlists.json"
    /// The one opening of the rows: every caller awaits the same task.
    private var rowsOpening: Task<KeyedRowStore<Playlist>?, Never>?
    /// What the rows hold, as far as this run knows: the last LANDED write
    /// or the start read. A failed start read leaves it unknown, and then
    /// no write removes a row nobody saw.
    private var rowBase: RowBase<[String: Playlist]> = .fresh

    /// The database and the document seam are chosen once; a witness
    /// hands in a file of its own for both.
    init(database: MaerDatabase = MaerDatabase.shared, ablage: Ablage = .documents) {
        self.database = database
        self.ablage = ablage
        load()
    }

    var totalEntries: Int { playlists.reduce(0) { $0 + $1.itemIds.count } }

    // MARK: - Reading

    func playlist(id: String) -> Playlist? { playlists.first { $0.id == id } }

    // MARK: - Writing

    @discardableResult
    func create(name: String, itemIds: [String] = []) -> Playlist {
        let kept = itemIds.filter { PlayQueue.canEnqueue($0) }
        let snapshots = Self.snapshots(for: kept)
        let list = Playlist(id: UUID().uuidString,
                            name: Self.uniqueName(name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                  among: playlists.map(\.name)),
                            updatedAt: Date().timeIntervalSince1970,
                            itemIds: kept,
                            titles: snapshots.mapValues(\.title),
                            snapshots: snapshots)
        playlists.append(list)
        save()
        return list
    }

    /// A new list never takes a name that is already there: two devices
    /// creating "New Playlist" at once are two lists with two ids, and the
    /// person cannot tell them apart. The second one counts. Pure.
    nonisolated static func uniqueName(_ wanted: String, among existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(wanted.lowercased()) else { return wanted }
        var counter = 2
        while taken.contains("\(wanted) \(counter)".lowercased()) { counter += 1 }
        return "\(wanted) \(counter)"
    }

    /// Outcome of adding. Nothing fails silently.
    enum AddOutcome: Equatable {
        case added
        /// Already there. Not an error, but not a silent repeat either.
        case alreadyThere
        /// The bound is reached; the number goes into the message.
        case limitReached(limit: Int)
        /// The type does not belong in a list. An endless stream is not a
        /// list entry. Same rule as the queue, no second gate concept.
        case notQueueable
    }

    /// `knownTitle` comes from the SURFACE that added the entry. It had
    /// the name on screen at the moment of the tap. The cache lookup is only
    /// the fallback now: with a cold catalogue cache it answers nil, and the
    /// snapshot loop used to `continue` wordlessly, which is how the user'
    /// shared list ended up as two "Unknown Title" rows on both devices.
    @discardableResult
    func add(itemId: String, to playlistId: String, knownTitle: String? = nil) -> AddOutcome {
        guard PlayQueue.canEnqueue(itemId) else { return .notQueueable }
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return .notQueueable }
        if playlists[index].itemIds.contains(itemId) { return .alreadyThere }
        guard totalEntries < Self.entryLimit else { return .limitReached(limit: Self.entryLimit) }
        playlists[index].itemIds.append(itemId)
        // The add moment is the witness that outlives a removal mark from
        // the other device; adding again spends the local mark.
        playlists[index].added[itemId] = Date().timeIntervalSince1970
        playlists[index].removed[itemId] = nil
        // The snapshot is taken NOW, while the item is at hand. After a cold
        // start on another device the id may be all that is left of it.
        // The seam answers with everything it knows; the surface's title is
        // the fallback that still names the entry when the cache is cold.
        if let carried = Self.snapshots(for: [itemId])[itemId]
            ?? Self.usableTitle(knownTitle, for: itemId).map({ CarriedItem(id: itemId, title: $0) }) {
            playlists[index].snapshots[itemId] = carried
            playlists[index].titles[itemId] = carried.title
        } else {
            // The one routine whose only job is holding the name on
            // says so when it comes away empty.
            Logger.library.notice("PLAYLIST snapshot EMPTY for id=\(itemId, privacy: .public) — row will need the detail fetch")
        }
        playlists[index].updatedAt = Date().timeIntervalSince1970
        save()
        return .added
    }

    /// A title is only worth persisting when it NAMES the entry: never the
    /// raw id, never the unknown-placeholder. A placeholder written into
    /// SYNCED data would poison every device's rows (the fence the old
    /// comment asked for, now one testable place).
    /// A title is only worth persisting when it NAMES the entry. The rule
    /// lives at the seam (`SyncCarried.usableTitle`); this is its name here.
    static func usableTitle(_ candidate: String?, for itemId: String) -> String? {
        SyncCarried.usableTitle(candidate, for: itemId)
    }

    /// What the seam can carry for these ids right now. Never the raw id,
    /// never a placeholder: a stub's placeholder title written into SYNCED
    /// data would poison every device's rows.
    private static func snapshots(for itemIds: [String]) -> [String: CarriedItem] {
        var out: [String: CarriedItem] = [:]
        for id in itemIds {
            if let carried = AppSession.shared.carried(forId: id) { out[id] = carried }
        }
        return out
    }

    /// Fill snapshots a list is still missing. Entries added before the
    /// snapshot existed, on the device that can resolve them. Runs when the
    /// list page appears; saves only when something was actually learned.
    func backfillTitles(playlistId: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        let missing = playlists[index].itemIds.filter { playlists[index].snapshots[$0] == nil }
        guard !missing.isEmpty else { return }
        let learned = Self.snapshots(for: missing)
        if !learned.isEmpty {
            playlists[index].snapshots.merge(learned) { old, _ in old }
            playlists[index].titles.merge(learned.mapValues(\.title)) { old, _ in old }
            save()
        }
        // The cache is only the shortcut. What it cannot answer goes
        // the SAME reload way the row goes, so a shared list heals itself
        // instead of staying at the placeholder forever.
        let stillMissing = playlists[index].itemIds.filter { playlists[index].snapshots[$0] == nil }
        guard !stillMissing.isEmpty else { return }
        Task { await fetchMissingTitles(stillMissing, playlistId: playlistId) }
    }

    /// Resolve entries the session cache does not carry (catalogue ids are
    /// self-describing) and write the won snapshot BACK. The healing then
    /// travels to every device with the list.
    func fetchMissingTitles(_ itemIds: [String], playlistId: String) async {
        var learned: [String: CarriedItem] = [:]
        for id in itemIds {
            let provider = AppSession.shared.provider(for: id)
            // Healing in the background is an automatic question.
            guard let detail = try? await LookupOccasion.automatic({
                try await provider.fetchItemDetail(itemId: id)
            }) else { continue }
            let fetched = LibraryItem(id: id, media: detail.media, addedAt: nil)
            if let carried = SyncCarried.snapshot(forId: id, known: fetched,
                                                  coverURL: provider.coverURL(forItemId: id)) {
                learned[id] = carried
            }
        }
        guard !learned.isEmpty,
              let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        playlists[index].snapshots.merge(learned) { old, _ in old }
        playlists[index].titles.merge(learned.mapValues(\.title)) { old, _ in old }
        Logger.library.notice("PLAYLIST healed \(learned.count) snapshot(s) via detail fetch")
        save()
    }

    /// What this device makes of an entry: the seam's answer with the
    /// entry's snapshot. Rows and cards ask this, nothing else.
    func resolution(of itemId: String, in list: Playlist) -> ItemResolution {
        AppSession.shared.resolve(forId: itemId, carried: list.carried(for: itemId))
    }

    /// Several at once (album, saving the queue). The bound counts per entry,
    /// as much is appended as fits, and the caller learns when something did
    /// not.
    @discardableResult
    func add(itemIds: [String], to playlistId: String,
             knownTitles: [String: String] = [:]) -> AddOutcome {
        var outcome = AddOutcome.added
        for id in itemIds {
            let result = add(itemId: id, to: playlistId, knownTitle: knownTitles[id])
            if case .limitReached = result { outcome = result; break }
        }
        return outcome
    }

    func remove(itemId: String, from playlistId: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        playlists[index].itemIds.removeAll { $0 == itemId }
        let now = Date().timeIntervalSince1970
        // The removal is a FACT that travels with the list (a tombstone per
        // entry); otherwise the other device's version hands the title back.
        playlists[index].removed[itemId] = now
        playlists[index].added[itemId] = nil
        playlists[index].updatedAt = now
        save()
    }

    func rename(playlistId: String, to name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        playlists[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Naming a rescue copy is the user adopting it. From here on it is an
        // ordinary list and travels with the others.
        playlists[index].isRescue = false
        playlists[index].updatedAt = Date().timeIntervalSince1970
        // The name's own clock. Without it a rename on the side that later
        // loses the list on content died silently in the merge.
        playlists[index].nameUpdatedAt = Date().timeIntervalSince1970
        save()
    }

    func delete(playlistId: String) {
        playlists.removeAll { $0.id == playlistId }
        // The deletion needs to be a FACT, not the absence of one. Otherwise
        // the next reconcile hands the list back.
        var marks = Self.tombstones
        marks[playlistId] = Date().timeIntervalSince1970
        Self.tombstones = marks
        save()
    }

    /// Adopt the state a merge produced. Rescue copies are appended, never
    /// pushed. See `MaerPlaylistMerge`.
    func apply(merged: [String: MaerPlaylistMerge.Entry],
               rescued: [MaerPlaylistMerge.Entry],
               tombstones marks: [String: Double],
               rescueName: (MaerPlaylistMerge.Entry) -> String,
               rescueReason: (MaerPlaylistMerge.Entry) -> String = { _ in "" }) {
        var next = playlists.filter { $0.isRescue }
        for (id, entry) in merged {
            next.append(Playlist(id: id, name: entry.name,
                                 updatedAt: entry.updatedAt, itemIds: entry.itemIds,
                                 titles: entry.titles, snapshots: entry.snapshots,
                                 nameUpdatedAt: entry.nameUpdatedAt, removed: entry.removed,
                                 added: entry.added))
        }
        let existing = next.map(\.itemIds)
        for candidate in rescued where MaerPlaylistMerge.needsRescue(candidate, existing: existing) {
            next.append(Playlist(id: UUID().uuidString, name: rescueName(candidate),
                                 isRescue: true, updatedAt: candidate.updatedAt,
                                 itemIds: candidate.itemIds, titles: candidate.titles,
                                 snapshots: candidate.snapshots, rescueReason: rescueReason(candidate)))
        }
        Self.tombstones = marks
        playlists = next.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
    }

    /// Every list with its entries in the form `map` gives (Navidrome's new
    /// ids), by the rule the runner reads the far side with. Mechanics: the
    /// list clock stays, so the move does not travel as a change of its own.
    /// Returns how many lists changed and how many there are.
    @discardableResult
    func rekey(_ map: (String) -> String) -> (changed: Int, total: Int) {
        var changed = 0
        let next = playlists.map { list -> Playlist in
            let entry = NavidromeRekey.playlist(
                .init(name: list.name, updatedAt: list.updatedAt, itemIds: list.itemIds, titles: list.titles,
                      nameUpdatedAt: list.nameUpdatedAt, snapshots: list.snapshots, removed: list.removed,
                      added: list.added), map)
            var moved = list
            moved.itemIds = entry.itemIds
            moved.titles = entry.titles
            moved.snapshots = entry.snapshots
            moved.removed = entry.removed
            moved.added = entry.added
            if moved != list { changed += 1 }
            return moved
        }
        if changed > 0 {
            playlists = next
            save()
        }
        return (changed, playlists.count)
    }

    /// Everything that may travel. Rescue copies stay here.
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

    // MARK: - Persistence: rows, the document once

    /// Rows first, synchronously through a reader (the store's load is
    /// synchronous by contract: the music tab reads the lists at once).
    /// The document is read only when the rows hold nothing, and then
    /// poured into them once; a failed rows read falls back to the
    /// document that was set aside and migrates nothing.
    private func load() {
        var loaded: [Playlist]?
        var base: RowBase<[String: Playlist]> = .fresh
        var rowsFailed = false
        do {
            // No file yet is a fresh install: nothing to read, fresh base.
            let reader = try database.readerNow()
            let rows = try reader.map { try KeyedRowStore<Playlist>.loadNow(table: .maerPlaylist, reader: $0) }
                ?? KeyedRowStore<Playlist>.Load(rows: [:], skipped: 0)
            if !rows.rows.isEmpty || rows.skipped > 0 {
                loaded = Self.ordered(rows.rows)
                // Rows that did not decode make the rows unknown, never
                // fresh; no document is poured over them.
                base = RowBase.afterLoad(rows: rows.rows.isEmpty ? nil : rows.rows, skipped: rows.skipped)
            }
        } catch {
            base = .unknown
            rowsFailed = true
            Logger.library.error("PLAYLIST rows read failed reason=\(String(describing: error), privacy: .public) fallback=migrated")
        }
        var migrate = false
        if loaded == nil {
            // Corrupt is kept aside by the seam and never buried by an
            // empty save; a missing file starts fresh.
            loaded = ablage.loadNow([Playlist].self, name: documentName).value
            if rowsFailed {
                loaded = loaded ?? ablage.loadNow([Playlist].self, name: documentName + ".migrated").value
            } else {
                migrate = loaded != nil
            }
        }
        playlists = loaded ?? []
        rowBase = base
        Logger.library.notice("PLAYLIST start: lists=\(self.playlists.count) entries=\(self.totalEntries) migrate=\(migrate)")
        if migrate { migrateDocument(playlists) }
    }

    /// The rows hold a dictionary; the lists are shown in name order, the
    /// order every merge round leaves them in.
    nonisolated static func ordered(_ rows: [String: Playlist]) -> [Playlist] {
        rows.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    nonisolated static func keyed(_ lists: [Playlist]) -> [String: Playlist] {
        Dictionary(lists.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// The document into the rows, whole, then set aside as `.migrated`
    /// (excluded from the backup; removed by the release after next).
    private func migrateDocument(_ lists: [Playlist]) {
        let document = ablage.url(for: documentName)
        pendingWrite = Task { [weak self] in
            guard let self, let rows = await self.openRows() else { return }
            let stock = Self.keyed(lists)
            do {
                let written = try await rows.replaceAll(stock)
                try DocumentMigration.setAside(document)
                self.rowBase = .known(stock)
                Logger.library.notice("PLAYLIST migrate: lists=\(written)")
            } catch {
                Logger.library.error("PLAYLIST migrate failed reason=\(String(describing: error), privacy: .public)")
            }
        }
    }

    private func openRows() async -> KeyedRowStore<Playlist>? {
        if let rowsOpening { return await rowsOpening.value }
        let opening = Task<KeyedRowStore<Playlist>?, Never> {
            do {
                return try await KeyedRowStore<Playlist>(connection: try database.connection(), table: .maerPlaylist)
            } catch {
                Logger.library.error("PLAYLIST rows open failed reason=\(String(describing: error), privacy: .public)")
                return nil
            }
        }
        rowsOpening = opening
        return await opening.value
    }

    /// Each write waits for the one before it, so the last state lands last.
    private var pendingWrite: Task<Void, Never>?

    /// The last handed-over write (witnesses).
    func awaitPendingWrites() async {
        await pendingWrite?.value
    }

    /// Only the lists that changed go to the rows, in order. A failure is
    /// logged; the lists live on in memory and the next change writes
    /// again (the carrier holds them too).
    private func save() {
        changed?()
        let snapshot = Self.keyed(playlists)
        let previous = pendingWrite
        pendingWrite = Task(priority: .utility) { [weak self] in
            await previous?.value
            guard let self, let rows = await self.openRows() else { return }
            // The base is read HERE, after the write before landed or failed.
            let base = self.rowBase
            do {
                switch base.plan {
                case .diff:
                    let written = try await rows.apply(previous: base.knownValue ?? [:], current: snapshot)
                    if written.upserted + written.removed > 0 {
                        Logger.library.notice("PLAYLIST save: lists=\(written.upserted)/-\(written.removed)")
                    }
                case .upsertOnly:
                    let written = try await rows.apply(previous: [:], current: snapshot)
                    Logger.library.notice("PLAYLIST save: upsertOnly lists=\(written.upserted)")
                }
                self.rowBase = .known(snapshot)
            } catch {
                Logger.library.error("PLAYLIST save failed reason=\(String(describing: error), privacy: .public) base kept")
            }
        }
    }
}
