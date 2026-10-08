// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The stores read their rows and nothing else. The documents they kept
/// before the rows were last written by v2.9; every device runs a build
/// that poured them long ago, so no store reads them, pours them or sets
/// them aside any more. A name below that comes back into the sources is a
/// reader of a form nobody writes.
struct RetiredDocumentsFenceTests {
    nonisolated static let retired = [
        "library_cache.json", "pending_sync.json", "syncHistory.json", "lastchecked.json",
        "maer_playlists.json", "DownloadsMeta", "playback_context.json", "local_library.json",
        "play_queue.json", "podcast_queue.json", "podcast-listen-log.json", "listening_stats.json",
        "DocumentMigration", "settingAside", ".migrated\""
    ]

    @Test("kein Speicher liest, giesst oder legt ein Dokument von vor den Zeilen beiseite", .needsTheSources)
    func noStoreReadsARetiredDocument() throws {
        var found: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            for name in Self.retired where code.contains(name) {
                found.append("\(file.lastPathComponent): \(name)")
            }
        }
        #expect(found.isEmpty, "a retired document is read again: \(found.sorted())")
    }

    /// The one-time steps whose source form every device left long ago:
    /// the catalog master's translation, the two keychain passes, the logo
    /// and feed picture generations, the two download repairs, the listen
    /// log's flag and the dotted stamp of the foreign marks, and the old
    /// forms other devices wrote. Their markers and keys stay out of the
    /// sources with them.
    nonisolated static let retiredSteps = [
        "sourcesTwoQuestionsMigrated", "migrateMasterIfNeeded",
        "keychainAccessibilityMigrated", "keychainRetiredServicePurged",
        "radioLogoChainVersion", "radioLogoChainResults", "feedArtworkResults",
        "downloadExtensionRepairV2", "downloadDeepValidationV1",
        "migrateSynthesizedFlag", "formerStampKey",
        // Other devices' old forms: the premium and block lists beside the
        // choices document. The one claim key every device shared has its
        // own test below.
        "legacyList", "legacyStatements", "premiumMarkedFeedsRemoved", "blockedFeedKeysRemoved"
    ]

    /// The one claim key every device shared, in whatever line it would
    /// come back. The one line allowed is the list of keys the user owns,
    /// where the name is a prefix that also covers each device's own key.
    @Test("der geteilte Anspruchs-Schluessel steht nur in der Liste der Nutzer-Schluessel", .needsTheSources)
    func theSharedClaimKeyIsGone() throws {
        var texts: [String: String] = [:]
        for file in ProjectFileIntegrityTests.sourceFiles() {
            texts[file.lastPathComponent] = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
        }
        #expect(texts["ClaimCarrier.swift"] != nil, "the precondition: the fence read the sources")
        #expect(Self.sharedClaimKeyLines(in: texts) == [], "the shared claim key is back")
        // Calibration: any line with the key counts, the allowed line does not.
        #expect(Self.sharedClaimKeyLines(in: ["A.swift": #"let key = "playbackClaim""#,
                                              "DerivedStores.swift": #"static let userOwnedPrefixes = ["localPosition.", "playbackClaim","#,
                                              "B.swift": #"static let claimKeyPrefix = "playbackClaim.""#])
                == [#"A.swift: let key = "playbackClaim""#])
    }

    /// Lines naming the shared claim key, except the user-owned prefix list.
    nonisolated static func sharedClaimKeyLines(in texts: [String: String]) -> [String] {
        var found: [String] = []
        for (file, text) in texts {
            for line in text.split(separator: "\n") where line.contains(#""playbackClaim""#) {
                if file == "DerivedStores.swift" && line.contains("userOwnedPrefixes") { continue }
                found.append("\(file): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        return found.sorted()
    }

    @Test("kein einmaliger Schritt von vor 3.3 kehrt mit Marker oder Schluessel zurueck", .needsTheSources)
    func noRetiredStepComesBack() throws {
        var found: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            for name in Self.retiredSteps where code.contains(name) {
                found.append("\(file.lastPathComponent): \(name)")
            }
        }
        #expect(found.isEmpty, "a retired step is back: \(found.sorted())")
    }
}
#endif
