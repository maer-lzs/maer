// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The bridge ferry of the bundle-id move: the LAST build of the old
/// `de.lzs` app EXPORTS the user's local belongings into the shared
/// app-group container, the new `fm.maer.app` app IMPORTS them on first
/// start. ONE versioned format on both sides, so the ferry cannot become
/// a migration trap of its own.
///
/// Freight (decided): subscriptions, local listening positions,
/// playlists. NOT aboard: server truth (Audiobookshelf owns its
/// progress), the derived catalog stock and day stores (the new app
/// fetches its own), credentials (fresh sign-in is an honest state, not
/// an error; the keychain does not cross bundle ids).
///
/// Both apps are built from the same code base; which side runs is
/// decided by the BUNDLE ID, so the ferry cannot run the wrong way on
/// either side.
nonisolated enum BridgeFerry {
    static let formatVersion = 1

    /// The manifest is written LAST on export: it is the seal of a whole
    /// shipment. A crash mid-export leaves files without a manifest, and
    /// the import reads that as "no shipment", never as an empty one.
    /// Codable-Bestandsregel: NEW fields must be optional. A required
    /// field would make an OLD manifest undecodable, and the import would
    /// read that as "no shipment" and wait forever; real format breaks go
    /// through `formatVersion` (refused loudly, tested).
    struct Manifest: Codable {
        var version: Int
        var exportedAt: Double
        var sourceBundleId: String
        var subscriptionBytes: Int
        var playlistBytes: Int
        var positionCount: Int
    }

    /// What the import found and took. The first start SHOWS this: no
    /// silent inheritance, and "nothing there" is distinguishable from
    /// "the bridge update never ran on the old app".
    struct Summary: Codable {
        var subscriptionsTaken: Bool
        var playlistsTaken: Bool
        var positionsTaken: Int
        var exportedAt: Double
    }

    static var directory: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
            .appendingPathComponent("bridge", isDirectory: true)
    }

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// The one key family that travels: the local positions (podcasts,
    /// catalog works, sideloads), the same family the iCloud channel
    /// syncs, gathered here for devices without iCloud.
    private static let positionPrefix = "localPosition."

    // MARK: - Export (the OLD app, every launch)

    /// Runs ONLY under the old bundle id, on every launch, so the ferry
    /// always carries the freshest state the old app ever had.
    static func exportIfOldApp(bundleId: String? = Bundle.main.bundleIdentifier,
                               directory: URL? = directory,
                               documents: URL = documents,
                               defaults: UserDefaults = .standard) {
        guard bundleId?.hasPrefix("de.lzs") == true else { return }
        guard let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            var subscriptionBytes = 0
            var playlistBytes = 0
            let subs = documents.appendingPathComponent("podcast_subscriptions.json")
            if let data = try? Data(contentsOf: subs) {
                try data.write(to: directory.appendingPathComponent("podcast_subscriptions.json"),
                               options: .atomic)
                subscriptionBytes = data.count
            }
            let lists = documents.appendingPathComponent("maer_playlists.json")
            if let data = try? Data(contentsOf: lists) {
                try data.write(to: directory.appendingPathComponent("maer_playlists.json"),
                               options: .atomic)
                playlistBytes = data.count
            }
            var positions: [String: [Double]] = [:]
            for (key, value) in defaults.dictionaryRepresentation()
                where key.hasPrefix(positionPrefix) {
                if let arr = value as? [Double] { positions[key] = arr }
                else if let nums = value as? [NSNumber] { positions[key] = nums.map(\.doubleValue) }
            }
            let positionData = try JSONEncoder().encode(positions)
            try positionData.write(to: directory.appendingPathComponent("positions.json"),
                                   options: .atomic)
            // The seal, last.
            let manifest = Manifest(version: formatVersion,
                                    exportedAt: Date().timeIntervalSince1970,
                                    sourceBundleId: bundleId ?? "",
                                    subscriptionBytes: subscriptionBytes,
                                    playlistBytes: playlistBytes,
                                    positionCount: positions.count)
            try JSONEncoder().encode(manifest)
                .write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
            Logger.library.notice("FERRY exported: subs=\(subscriptionBytes)B lists=\(playlistBytes)B positions=\(positions.count)")
        } catch {
            Logger.library.error("FERRY export failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Import (the NEW app, first start, once)

    private static let importedMarker = AppStorageKeys.bridgeFerryImported
    /// The shown-once flag of the first-start notice (separate from the
    /// import itself: the notice may wait for a UI, the import may not).
    static let noticeKey = AppStorageKeys.bridgeFerryNotice

    /// Runs ONLY under the new bundle id, once. Existing local data is
    /// never overwritten (a first start has none; a re-install that
    /// already accumulated data keeps it; the ferry never destroys).
    @discardableResult
    static func importIfNeeded(bundleId: String? = Bundle.main.bundleIdentifier,
                               directory: URL? = directory,
                               documents: URL = documents,
                               defaults: UserDefaults = .standard) -> Summary? {
        guard bundleId?.hasPrefix("fm.maer") == true else { return nil }
        guard defaults.object(forKey: importedMarker) == nil else { return nil }
        guard let directory,
              let manifestData = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData) else {
            // No seal: the bridge update never ran (or never finished).
            // Not an error, and NOT marked done: a later old-app launch
            // may still deliver, and this import will then take it.
            Logger.library.notice("FERRY import: no shipment yet")
            return nil
        }
        guard manifest.version == formatVersion else {
            Logger.library.error("FERRY import refused: format v\(manifest.version) (mine: v\(formatVersion))")
            return nil
        }
        var summary = Summary(subscriptionsTaken: false, playlistsTaken: false,
                              positionsTaken: 0, exportedAt: manifest.exportedAt)
        let subsTarget = documents.appendingPathComponent("podcast_subscriptions.json")
        if !FileManager.default.fileExists(atPath: subsTarget.path),
           let data = try? Data(contentsOf: directory.appendingPathComponent("podcast_subscriptions.json")) {
            try? data.write(to: subsTarget, options: .atomic)
            summary.subscriptionsTaken = true
        }
        let listsTarget = documents.appendingPathComponent("maer_playlists.json")
        if !FileManager.default.fileExists(atPath: listsTarget.path),
           let data = try? Data(contentsOf: directory.appendingPathComponent("maer_playlists.json")) {
            try? data.write(to: listsTarget, options: .atomic)
            summary.playlistsTaken = true
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("positions.json")),
           let positions = try? JSONDecoder().decode([String: [Double]].self, from: data) {
            for (key, value) in positions where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
                summary.positionsTaken += 1
            }
        }
        defaults.set(true, forKey: importedMarker)
        if let encoded = try? JSONEncoder().encode(summary) {
            defaults.set(encoded, forKey: noticeKey)
        }
        Logger.library.notice("FERRY imported: subs=\(summary.subscriptionsTaken) lists=\(summary.playlistsTaken) positions=\(summary.positionsTaken)")
        return summary
    }

    /// The pending first-start notice, consumed by the UI (read once,
    /// then cleared by the caller after showing).
    static func pendingNotice() -> Summary? {
        guard let data = UserDefaults.standard.data(forKey: noticeKey) else { return nil }
        return try? JSONDecoder().decode(Summary.self, from: data)
    }

    static func clearNotice() {
        UserDefaults.standard.removeObject(forKey: noticeKey)
    }
}
