// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The cleanup of 3.9: small debts the readers found, each with its witness.
struct CleanupThreeNineTests {
    private static func source(_ path: String) throws -> String {
        SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
    }

    private static func raw(_ path: String) throws -> String {
        try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("the own last claim under another id of this device is no foreign hint; a claim of another moment still is")
    func ownClaimIsNoHint() {
        let now = 1_000_000.0
        let own = PlaybackClaim(deviceId: "lasting-id", itemId: "rss:f:ep", t: now - 1_000, title: "Ep", deviceName: "iPhone")
        #expect(PlaybackClaimRules.hintClaim(claim: own, ownDeviceId: "spare-id", ownLast: own, nowMs: now) == nil,
                "this device's own claim, read back under its other id")
        var later = own
        later.t = now - 500
        #expect(PlaybackClaimRules.hintClaim(claim: later, ownDeviceId: "spare-id", ownLast: own, nowMs: now) == later,
                "another moment is another device's claim")
        #expect(PlaybackClaimRules.hintClaim(claim: own, ownDeviceId: "spare-id", ownLast: nil, nowMs: now) == own)
    }

    @Test("every reader of the hint hands the own last claim in", .needsTheSources)
    func readersHandTheOwnClaim() throws {
        #expect(try Self.source("Sources/Networking/PlaybackClaimSync.swift").contains("ownLast: lastOwnClaim"))
        #expect(try Self.source("Sources/Views/PlayingNow.swift").contains("ownLast: PlaybackClaimSync.shared.lastOwnClaim"))
        #expect(try Self.source("Sources/ViewModels/PlayerCoordinator.swift").contains("ownLast: PlaybackClaimSync.shared.lastOwnClaim"))
    }

    @Test("an unsubscribed show leaves no device keys behind; what travels stays") @MainActor
    func unsubscribeForgetsDeviceKeys() throws {
        let suite = "cleanup-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let show = "feed:example"
        let local = ["podcastAutoDownload.", "podcastAutoDownloadMode.", "podcastAutoDownloadSince.",
                     "podcastAutoDownloadKeep.", "podcastUpNextAddSince.", "podcastAutoDownloadError."]
        for key in local { defaults.set("x", forKey: key + show) }
        defaults.set("newest", forKey: PodcastAutoDownload.directionKey(show))
        PodcastAutoDownload.forgetLocal(show, defaults: defaults)
        for key in local { #expect(defaults.object(forKey: key + show) == nil, "\(key) stays") }
        #expect(defaults.string(forKey: PodcastAutoDownload.directionKey(show)) == "newest", "the direction travels and stays")
    }

    @Test("both ways a show is unsubscribed forget its device keys", .needsTheSources)
    func bothUnsubscribesForget() throws {
        let code = try Self.source("Sources/Providers/PodcastSubscriptions.swift")
        #expect(code.components(separatedBy: "PodcastAutoDownload.forgetLocal(").count - 1 == 2)
    }

    @Test("routines: no dead picks, the rule's cover says why it may carry access, the lists' comment names their one observer", .needsTheSources)
    func routineDebts() throws {
        #expect(!(try Self.source("Sources/Providers/RoutinePlayback.swift")).contains("static func picks("))
        #expect(try Self.raw("Sources/Providers/RoutinePlayback.swift").contains("stays on this device, so a picture address that carries access is fine"))
        #expect(!(try Self.raw("Sources/Views/LibraryView.swift")).contains("never observed"))
    }

    @Test("the widget's rows say why they could not be read", .needsTheSources)
    func continueRowsLog() throws {
        let code = try Self.source("Sources/Models/WidgetShared.swift")
        let body = try #require(code.components(separatedBy: "static func load() -> ContinueRows?").dropFirst().first)
            .components(separatedBy: "func save()").first ?? ""
        #expect(!body.contains("try?"), "a row file that does not read goes silent")
        #expect(body.contains("WidgetLog.logger"))
    }

    @Test("the inventory says where the walk over the old stands runs", .needsTheSources)
    func signpostRow() throws {
        let row = try #require(try Self.raw("docs/components.md").split(separator: "\n").first { $0.hasPrefix("| **`PerfSignpost`**") })
        #expect(!row.contains("vor dem ersten Bild"))
    }

    @Test("a tight tab bar names the source it cuts")
    func carTabsNameTheCut() {
        let tight = CarPlayLayout.tabs(audiobooks: true, podcasts: true, music: true, radio: false, maximumTabCount: 3)
        #expect(tight.tabs == [.start, .audiobooks, .podcasts])
        #expect(tight.cut == [.music])
        let roomy = CarPlayLayout.tabs(audiobooks: true, podcasts: true, music: true, radio: true, maximumTabCount: 5)
        #expect(roomy.cut.isEmpty)
    }

    @Test("the sound filter's outcome holds its item, not an address a new item can reuse", .needsTheSources)
    func soundAttachHoldsTheItem() throws {
        #expect(!(try Self.source("Sources/ViewModels/PlayerViewModel.swift")).contains("soundAttach: (item: ObjectIdentifier"))
    }

    @Test("the decision pattern lets a one-digit date through on purpose")
    func oneDigitDatesPass() {
        #expect(!ProjectFileIntegrityTests.decisionWords(in: "decided 06.09.").isEmpty)
        #expect(ProjectFileIntegrityTests.decisionWords(in: "decided 6.9.").isEmpty,
                "one-digit dates pass on purpose, so a reference like 'see 3.5.' is no decision")
    }
}
#endif
