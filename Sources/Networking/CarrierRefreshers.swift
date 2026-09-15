// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The one register of the carriers that are running: the pot, the
/// statistics, the playlists and the choices on CloudKit, and the sync
/// service's session for all of its documents at once. Each signs in when
/// it starts, and the two occasions that are not the start (the scene
/// coming back, a silent push) ask this register instead of naming
/// carriers. Before it, the push handler and the scene handler named only
/// the pot, and the other three families reached the other device at its
/// next cold start (measured on two devices, 14.09.2026). A push names its
/// zone; the carrier of that zone fetches and the others stay quiet. A
/// push without a zone, or with a zone nobody registered, wakes every
/// carrier. Entries are weak: a carrier that is gone is a skipped entry,
/// never a dangling refresh.
///
/// Every entry brings its OWN gate, because the switches differ: the
/// CloudKit families hang on the iCloud switch, the service's session does
/// not. The register asked the iCloud switch for everyone while it served
/// CloudKit alone; the service carrier registered behind that gate would
/// have gone quiet whenever iCloud was off, which is exactly the case in
/// which it is the only transport left.
@MainActor
enum CarrierRefreshers {
    private struct Entry {
        weak var carrier: AnyObject?
        let zone: String
        let gate: @MainActor () -> Bool
        let refresh: @MainActor (String) async -> Void
    }
    private static var entries: [Entry] = []

    /// A carrier signs in with the zone it fetches; signing in twice
    /// replaces the earlier entry.
    static func register(_ carrier: AnyObject, zone: String,
                         gate: @escaping @MainActor () -> Bool,
                         refresh: @escaping @MainActor (String) async -> Void) {
        entries.removeAll { $0.carrier == nil || $0.carrier === carrier }
        entries.append(Entry(carrier: carrier, zone: zone, gate: gate, refresh: refresh))
    }

    /// The zones with a living carrier, for the witness.
    static var zones: [String] {
        entries.filter { $0.carrier != nil }.map(\.zone)
    }

    /// Every living carrier fetches; returns how many were asked.
    @discardableResult
    static func refreshAll(by caller: String) async -> Int {
        await refresh(zone: nil, by: caller)
    }

    /// The carrier of `zone` fetches; without a zone, or with one nobody
    /// registered, every carrier does. Each entry's own gate decides whether
    /// it is asked at all, so the iCloud switch silences the four CloudKit
    /// families and leaves the service alone. The carriers are asked one
    /// after the other; each fetch is short and a carrier already fetching
    /// answers at once.
    @discardableResult
    static func refresh(zone: String?, by caller: String) async -> Int {
        entries.removeAll { $0.carrier == nil }
        let living = entries.filter { $0.gate() }
        let chosen = living.filter { zone == nil || $0.zone == zone }
        let asked = chosen.isEmpty ? living : chosen
        Logger.library.notice("CLOUDKIT refresh by=\(caller, privacy: .public) zone=\(zone ?? "-", privacy: .public) carriers=\(asked.map(\.zone).joined(separator: ","), privacy: .public)")
        for entry in asked { await entry.refresh(caller) }
        return asked.count
    }
}
