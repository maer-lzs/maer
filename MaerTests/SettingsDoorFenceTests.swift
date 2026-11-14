// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// `UserDefaults.standard` has three homes: the settings door
/// (`AppStorageKeys` and its extensions), the listening stock
/// (`ListeningStore`) and the storage layer (Ablage, Storage). Everything
/// else asks the door. The stock below is the count, both ways
/// (`StockDrift`); it is empty since the move is complete.
struct SettingsDoorFenceTests {
    /// The three homes of the key pot, each with its reason IN the entry.
    /// `AppStorageKeys` is given as a PREFIX because the door is spread
    /// over several files.
    nonisolated static let homes: [(match: String, reason: String)] = [
        ("/Sources/Storage/", "die Zeilen-Schicht, die ihren eigenen Bestand haelt"),
        ("/Ablage.swift", "die Datei-Naht, die neben den Zeilen steht"),
        ("/ListeningStore.swift", "der Hoerbestand, der eigene Schluessel fuehrt"),
        ("AppStorageKeys", "die Tuer selbst, ueber ihre Dateien verteilt"),
    ]

    nonisolated static func isAHome(_ path: String) -> Bool {
        homes.contains { entry in
            entry.match.hasPrefix("/")
                ? path.contains(entry.match)
                : URL(fileURLWithPath: path).lastPathComponent.hasPrefix(entry.match)
        }
    }

    nonisolated static func sites(in text: String) -> Int {
        text.components(separatedBy: "UserDefaults.standard").count - 1
    }

    /// The remaining sites outside the homes, by file. Empty: the move is
    /// complete (154 sites in 43 files on the day the fence was built). A
    /// new site anywhere is red.
    nonisolated static let stock: [String: Int] = [:]

    /// The other spelling of the same reach: a default value in a function
    /// head (`defaults: UserDefaults = .standard`). It is a test seam (a
    /// witness hands in its own store), and in the app it reaches the store
    /// past the door all the same; the literal count above never saw it.
    /// Read whitespace-free and outside comment lines.
    nonisolated static func seamSites(in text: String) -> Int {
        StockDriftTests.squeezed(SyncContractFenceTests.stripped(text))
            .components(separatedBy: "UserDefaults=.standard").count - 1
    }

    /// The seam defaults outside the homes, by file, measured 11.10.2026:
    /// 129 in 34 files; the stock is the count. Each is the store a witness
    /// replaces and the app passes by; the class is named here so a new one
    /// is seen, and it falls as stores move behind the door.
    /// BESTAND OHNE EINZELGRUENDE: one reason covers every entry, the seam
    /// of a store that is not behind the door yet.
    nonisolated static let seamStock: [String: Int] = ["RadioModels.swift": 30, "PodcastSubscriptions.swift": 12, "PodcastHelpers.swift": 9, "ForeignMarks.swift": 8, "BrowsedEpisodes.swift": 5, "KnownServers.swift": 5, "PodcastFeedAuth.swift": 5, "ContinueHidden.swift": 4, "FeedAdoptionPending.swift": 4, "FeedRefusal.swift": 4, "RecentSearches.swift": 4, "AppRows.swift": 3, "DeadCatalogItems.swift": 3, "FreeCatalogClients.swift": 3, "PlayedTail.swift": 3, "PodcastShowMode.swift": 3, "ContinueSources.swift": 2, "CorruptStore.swift": 2, "ExternalSources.swift": 2, "NavidromeRekeyRun.swift": 2, "RadioGenreSources.swift": 2, "RadioLogoService.swift": 2, "ResolutionCacheStore.swift": 2, "AccessFollowers.swift": 1, "ArchiveMetadataLoader.swift": 1, "BookmarkMeasure.swift": 1, "DerivedStores.swift": 1, "FreeCatalogLoader.swift": 1, "MaerSyncSignIn.swift": 1, "PodcastCloudSync.swift": 1, "PodcastComponents.swift": 1, "PodcastServerSave.swift": 1, "PodcastShowSettingsSheet.swift": 1, "UserChoiceCloudSync.swift": 1]

    // Both counts read the source tree: without it they are skipped, never
    // red (a stock with entries) and never green (an empty stock). The
    // readers are probed apart from them and run everywhere.
    @Test("the default UserDefaults = .standard in a function head is counted as a test seam, per file equal to the count", .needsTheSources)
    func theSeamDefaultIsCounted() throws {
        var counts: [String: Int] = [:]
        for file in ProjectFileIntegrityTests.sourceFiles() where !Self.isAHome(file.path) {
            let count = Self.seamSites(in: try String(contentsOf: file, encoding: .utf8))
            guard count > 0 else { continue }
            counts[file.lastPathComponent, default: 0] += count
        }
        let drift = StockDrift.findings(counts: counts, stock: Self.seamStock)
        #expect(drift.isEmpty, "a seam default reaches the store past the door unseen, or a stock above the count: \(drift)")
    }

    @Test("the readers of both counts: the default in a function head, the literal, the homes")
    func theReadersRead() {
        #expect(Self.seamSites(in: "func f(defaults: UserDefaults = .standard) {}") == 1)
        #expect(Self.seamSites(in: "func f(defaults:UserDefaults=.standard) {}") == 1)
        #expect(Self.seamSites(in: "// func f(defaults: UserDefaults = .standard)") == 0)
        #expect(Self.seamSites(in: "let x = UserDefaults.standard") == 0, "the literal belongs to the other count")
        #expect(Self.sites(in: "let x = UserDefaults.standard.bool(forKey: k)") == 1)
        #expect(Self.sites(in: "let x = AppStorageKeys.bool(k)") == 0)
        #expect(Self.isAHome("/x/Sources/Models/AppStorageKeys+Door.swift"))
        #expect(!Self.isAHome("/x/Sources/Views/SettingsView.swift"))
    }

    @Test("UserDefaults.standard only in the door, the stock and the storage layer; the rest shrinks", .needsTheSources)
    func onlyTheDoorsTouchTheStore() throws {
        var counts: [String: Int] = [:]
        for file in ProjectFileIntegrityTests.sourceFiles() where !Self.isAHome(file.path) {
            let count = Self.sites(in: try String(contentsOf: file, encoding: .utf8))
            guard count > 0 else { continue }
            counts[file.lastPathComponent, default: 0] += count
        }
        let drift = StockDrift.findings(counts: counts, stock: Self.stock)
        #expect(drift.isEmpty, "these files reach past the door, or a stock above the count: \(drift)")
    }
}
#endif
