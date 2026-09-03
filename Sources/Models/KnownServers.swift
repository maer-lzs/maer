// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The register of addresses that DEMONSTRABLY worked.
///
/// Password managers deliver user and password. The part a self-hoster
/// mistypes is the ADDRESS, and every form only ever knew its own last one
/// (Y26). This is the cross-service memory: whoever runs `music.maer.fm`
/// should not have to reassemble the next subdomain by hand.
///
/// **Never credentials.** Only the address, its service type and the date it
/// last worked. Credentials stay in the keychain; hostnames are private, so
/// nothing here is ever logged.
///
/// **Never deleted automatically** (an outage is not a reason
/// to delete anything). An entry leaves only by hand.
///
/// Hook: this is deliberately a plain, codable value list. When the
/// iCloud config travel arrives (after the ID flip), it only has to
/// transport this array. No reshaping.
nonisolated struct KnownServer: Codable, Equatable, Identifiable, Sendable {
    enum Service: String, Codable, Sendable, CaseIterable {
        case audiobookshelf, subsonic, jellyfin, gpodder, pinchflat
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

    static func all(defaults: UserDefaults = .standard) -> [KnownServer] {
        guard let data = defaults.data(forKey: storeKey),
              let list = try? JSONDecoder().decode([KnownServer].self, from: data) else { return [] }
        return list
    }

    /// Register an address. ONLY on a successful connection. Re-registering
    /// refreshes the date instead of creating a duplicate.
    static func remember(_ url: String, service: KnownServer.Service,
                         now: Double = Date().timeIntervalSince1970,
                         defaults: UserDefaults = .standard) {
        let trimmed = normalized(url)
        guard !trimmed.isEmpty else { return }
        var list = all(defaults: defaults)
        if let index = list.firstIndex(where: { $0.url == trimmed && $0.service == service }) {
            list[index].lastSuccessAt = now
        } else {
            list.append(KnownServer(url: trimmed, service: service, lastSuccessAt: now))
        }
        write(list, defaults: defaults)
    }

    /// By hand only (long-press on a suggestion).
    static func forget(_ entry: KnownServer, defaults: UserDefaults = .standard) {
        write(all(defaults: defaults).filter { $0.id != entry.id }, defaults: defaults)
    }

    /// Suggestions for a form: OWN service type first (most likely), the rest
    /// below. The value of a foreign entry is its domain family. Newest
    /// success first within each group.
    static func suggestions(for service: KnownServer.Service,
                            defaults: UserDefaults = .standard) -> [KnownServer] {
        let list = all(defaults: defaults).sorted { $0.lastSuccessAt > $1.lastSuccessAt }
        return list.filter { $0.service == service } + list.filter { $0.service != service }
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
            guard !url.isEmpty, !list.contains(where: { $0.url == url && $0.service == entry.service })
            else { continue }
            list.append(KnownServer(url: url, service: entry.service, lastSuccessAt: now))
        }
        write(list, defaults: defaults)
    }

    static func normalized(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    private static func write(_ list: [KnownServer], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: storeKey)
        NotificationCenter.default.post(name: didChange, object: nil, userInfo: ["defaults": defaults])
    }
}
