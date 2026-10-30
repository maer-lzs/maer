// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The register of addresses that DEMONSTRABLY worked.
///
/// Password managers deliver user and password. The part a self-hoster
/// mistypes is the ADDRESS, and every form only ever knew its own last one.
/// This is the cross-service memory: whoever runs `music.maer.fm`
/// should not have to reassemble the next subdomain by hand.
///
/// **Never credentials.** Only the address, its service type and the date it
/// last worked. Credentials stay in the keychain; hostnames are private, so
/// nothing here is ever logged.
///
/// **Never deleted automatically** (an outage is not a reason
/// to delete anything). An entry leaves only by hand.
///
/// **The same server** is one question with one answer,
/// `ABSServerScope.identity`: finding an entry again and offering it ask
/// there. An entry keeps the spelling it was stored in, because its id
/// (`service|url`) travels as a tombstone: a move to the name would leave a
/// hand-made removal on another device without an entry to remove, and an
/// older build would bring the old spelling back as a second one.
///
/// Hook: this is deliberately a plain, codable value list. When the
/// iCloud config travel arrives (after the ID flip), it only has to
/// transport this array. No reshaping.
nonisolated struct KnownServer: Codable, Equatable, Identifiable, Sendable {
    /// `maerSync`: the sync service's address, so a second
    /// device is offered it under its field. An older build reads the
    /// travelling entry as an unknown service and leaves it unstamped until
    /// it updates; the entries travel one by one, never as one list.
    enum Service: String, Codable, Sendable, CaseIterable {
        case audiobookshelf, subsonic, jellyfin, gpodder, pinchflat, maerSync
    }

    let url: String
    let service: Service
    /// Epoch seconds of the last SUCCESSFUL connection.
    var lastSuccessAt: Double

    var id: String { "\(service.rawValue)|\(url)" }
}

nonisolated enum KnownServers {
    static let storeKey = "knownServers"
    /// Posted after every write, so the iCloud travel of the register
    /// notes the change without this store knowing the cloud.
    static let didChange = Notification.Name("KnownServersDidChange")

    /// Read ENTRY BY ENTRY: one entry a build cannot read (a service a
    /// later build added) costs that entry, never the list. A whole-list
    /// decode read such a list as empty, and the next success wrote the
    /// empty list back with one entry.
    static func all(defaults: UserDefaults = .standard) -> [KnownServer] {
        entries(defaults: defaults).compactMap(\.known)
    }

    /// One stored entry: readable, or kept as it was for the build that can.
    private struct Stored: Decodable {
        let known: KnownServer?
        let raw: Any?

        init(from decoder: Decoder) throws {
            known = try? KnownServer(from: decoder)
            raw = nil
        }

        init(known: KnownServer?, raw: Any?) {
            self.known = known
            self.raw = raw
        }
    }

    private static func entries(defaults: UserDefaults) -> [Stored] {
        guard let data = defaults.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([Stored].self, from: data) else { return [] }
        guard decoded.contains(where: { $0.known == nil }),
              let raws = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
              raws.count == decoded.count else { return decoded }
        return zip(decoded, raws).map { Stored(known: $0.known, raw: $0.known == nil ? $1 : nil) }
    }

    /// Register an address. ONLY on a successful connection. Re-registering
    /// the same server, also under another spelling, refreshes the date
    /// instead of creating a duplicate.
    static func remember(_ url: String, service: KnownServer.Service,
                         now: Double = Date().timeIntervalSince1970,
                         defaults: UserDefaults = .standard) {
        let trimmed = normalized(url)
        guard !trimmed.isEmpty else { return }
        var list = all(defaults: defaults)
        if let index = list.firstIndex(where: { sameServer($0.url, trimmed) && $0.service == service }) {
            list[index].lastSuccessAt = now
        } else {
            list.append(KnownServer(url: trimmed, service: service, lastSuccessAt: now))
        }
        write(list, defaults: defaults)
    }

    /// By hand only (long-press on a suggestion). The removed id travels
    /// in the notification: a tombstone in the cloud comes only from this
    /// gesture, never from an entry that is merely absent here.
    static func forget(_ entry: KnownServer, defaults: UserDefaults = .standard) {
        write(all(defaults: defaults).filter { $0.id != entry.id }, defaults: defaults,
              removed: entry.id)
    }

    /// Suggestions for a form: OWN service type first (most likely), the rest
    /// below. The value of a foreign entry is its domain family. Newest
    /// success first within each group, one per server and service: two
    /// spellings stored before the one name are one suggestion, the newer.
    /// The sync service and the media servers never stand under each other:
    /// a sync service serves no media, and a media server keeps no sync.
    static func suggestions(for service: KnownServer.Service,
                            defaults: UserDefaults = .standard) -> [KnownServer] {
        var seen: Set<String> = []
        let list = all(defaults: defaults).sorted { $0.lastSuccessAt > $1.lastSuccessAt }
            .filter { seen.insert("\($0.service.rawValue)|\(ABSServerScope.identity(of: $0.url))").inserted }
        return list.filter { $0.service == service }
            + list.filter { $0.service != service && sameKind($0.service, service) }
    }

    /// Whether two stored addresses name the same server, by its one name.
    static func sameServer(_ a: String, _ b: String) -> Bool {
        ABSServerScope.identity(of: a) == ABSServerScope.identity(of: b)
    }

    /// Whether two services are offered under each other: media servers among
    /// themselves, the sync service only under its own field.
    static func sameKind(_ a: KnownServer.Service, _ b: KnownServer.Service) -> Bool {
        (a == .maerSync) == (b == .maerSync)
    }

    /// One-off backfill: the addresses currently configured across the
    /// services move into the register, so the memory is not empty on the
    /// first launch after the update.
    static func backfill(_ existing: [(url: String, service: KnownServer.Service)],
                         now: Double = Date().timeIntervalSince1970,
                         defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: storeKey) == nil else { return }
        var list: [KnownServer] = []
        for entry in existing {
            let url = normalized(entry.url)
            guard !url.isEmpty, !list.contains(where: { sameServer($0.url, url) && $0.service == entry.service })
            else { continue }
            list.append(KnownServer(url: url, service: entry.service, lastSuccessAt: now))
        }
        write(list, defaults: defaults)
    }

    /// Trimmed, without trailing slashes, and WITHOUT a user or password
    /// in the address: `https://name:secret@host` is a real self-hoster
    /// form, and the register travels between devices. It remembers the
    /// host, never the secret.
    static func normalized(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if text.contains("@"), var components = URLComponents(string: text),
           components.user != nil || components.password != nil {
            components.user = nil
            components.password = nil
            if let stripped = components.string { text = stripped }
        }
        return text
    }

    /// A list that does not decode even entry by entry (no list at all)
    /// reads as none and is set aside before the write.
    private static func write(_ list: [KnownServer], defaults: UserDefaults, removed: String? = nil) {
        CorruptStore.setAsideUnreadable([Stored].self, defaultsKey: storeKey, defaults: defaults,
                                        label: "KNOWN servers")
        // bearable, because text and a finite date always encode
        guard var data = try? JSONEncoder().encode(list) else { return }
        // Entries this build cannot read go back as they were.
        let unreadable = entries(defaults: defaults).compactMap(\.raw)
        if !unreadable.isEmpty,
           let written = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
           let merged = try? JSONSerialization.data(withJSONObject: written + unreadable) {
            data = merged
        }
        defaults.set(data, forKey: storeKey)
        var info: [String: Any] = ["defaults": defaults]
        if let removed { info["removed"] = removed }
        NotificationCenter.default.post(name: didChange, object: nil, userInfo: info)
    }
}
