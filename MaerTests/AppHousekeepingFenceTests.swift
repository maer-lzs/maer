// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The start of the app and every scene change belonged to `LibraryView`: 42
/// singleton handles in a view whose job is hosting the tabs. They were
/// there for a single reason, namely that the library happens to be the
/// first screen.
///
/// The fence holds two things, and the second is the more important:
///
/// 1. The view does not take the housekeeping back.
/// 2. **The ORDER.** It used to be a property of a 1584-line view body and
///    could not be stated anywhere. It follows the same rule that the
///    catalog runs follow: housekeeping comes
///    AFTER the content that is waited for.
struct AppHousekeepingFenceTests {
    private func sourceText(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func codeOf(_ relative: String) throws -> String {
        try sourceText(relative)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Stock with a reason per name. All at ZERO: none of these services has
    /// any business in the view, and whoever brings one back must touch this
    /// entry.
    @Test("The tab host no longer calls an app service itself", .needsTheSources)
    func theTabHostCallsNoAppServiceItself() throws {
        let forbidden: [String: String] = [
            "SyncQueue": "Fortschritts-Warteschlange, gehoert AppHousekeeping.flushQueues (zwei Rufer)",
            "BookmarkQueue": "Lesezeichen-Warteschlange, dieselbe Tuer wie SyncQueue",
            "CloudQuotaWatch": "iCloud-Kontingent, steht VOR den Diensten und haengt an keinem",
            "PodcastCloudSync": "Podcast-Fortschritt ueber iCloud, Start und beide Szenen-Zweige",
            "ListeningStatsStore": "Hoerstatistik, derselbe Schalter",
            "MaerPlaylistCloudSync": "Playlists reisen mit dem Podcast-Fortschritt",
            "UserChoiceCloudSync": "die reisenden Nutzer-Entscheidungen",
            "PlaybackClaimSync": "Uebernahme-Kanal",
        ]
        let code = try codeOf("Sources/Views/LibraryView.swift")
        var offenders: [String] = []
        for name in forbidden.keys.sorted() where code.contains(name) { offenders.append(name) }
        #expect(offenders.isEmpty, "LibraryView ruft App-Dienste selbst: \(offenders)")
    }

    /// `Artwork` is deliberately NOT in the list above, and the reason
    /// belongs here instead of in an exception: the two unconditional
    /// sweep runs (start, background) are housekeeping and have moved. The
    /// third hangs on the CALM GATE, and „wann ruht das Scrollen" is the
    /// question of the view. Had I taken it along, `AppHousekeeping` would
    /// have become a type that is not a view and schedules UI work, exactly
    /// the stock that `ScrollCalmFenceTests` counts down as way B. This
    /// fence caught it one run before the commit.
    @Test("The cover cap on coming back stays at the calm gate of the view", .needsTheSources)
    func theCalmGatedSweepStaysInTheView() throws {
        let code = try codeOf("Sources/Views/LibraryView.swift")
        #expect(code.contains("Artwork.sweepIfOverCap"),
                "der Deckel-Lauf beim Zurueckkommen ist verschwunden")
        #expect(!code.contains("Artwork.sweep()"),
                "ein bedingungsloser Fegelauf ist in die Ansicht zurueckgekehrt")
        // And it really hangs on the gate, not beside it.
        guard let calm = code.range(of: "ScrollCalm.run"),
              let sweep = code.range(of: "Artwork.sweepIfOverCap") else {
            Issue.record("eine der zwei Marken fehlt"); return
        }
        #expect(calm.lowerBound < sweep.lowerBound,
                "der Fegelauf steht nicht mehr im Ruhe-Tor")
        // Counter-check: the housekeeping does NOT hold the gate, otherwise
        // the way-B stock would have gone up by one.
        #expect(!(try codeOf("Sources/ViewModels/AppHousekeeping.swift")).contains("ScrollCalm"),
                "AppHousekeeping plant UI-Arbeit ein und erhoeht damit Weg B")
    }

    /// The order in the source text. A witness cannot run a `.task`, so the
    /// POSITION is checked, which is exactly the statement that stood
    /// nowhere before.
    @Test("The housekeeping comes after Library and Continue Listening", .needsTheSources)
    func housekeepingStandsBehindTheContent() throws {
        let code = try codeOf("Sources/Views/LibraryView.swift")
        guard let cachedLibrary = code.range(of: "showCachedLibraryIfAvailable"),
              let restore = code.range(of: "restoreLastSession"),
              let maintenance = code.range(of: "AppHousekeeping.maintenance()"),
              let services = code.range(of: "AppHousekeeping.startServices()")
        else {
            Issue.record("eine der vier Marken fehlt: die Startsequenz wurde umgebaut")
            return
        }
        #expect(cachedLibrary.lowerBound < maintenance.lowerBound,
                "die Wartung steht wieder VOR der zwischengespeicherten Bibliothek")
        #expect(restore.lowerBound < maintenance.lowerBound,
                "die Wartung steht vor dem Weiterhoeren")
        #expect(services.lowerBound < maintenance.lowerBound,
                "die Wartung ist nicht mehr der letzte Schritt")
    }

    /// And the opposite direction, so that the case above is not green
    /// because the marks stand somewhere: the housekeeping itself really
    /// names its services too, otherwise the stock above guards an empty file.
    @Test("The housekeeping names the services it has taken over", .needsTheSources)
    func housekeepingActuallyHoldsThem() throws {
        let code = try codeOf("Sources/ViewModels/AppHousekeeping.swift")
        for name in ["SyncQueue", "BookmarkQueue", "CloudQuotaWatch", "PodcastCloudSync",
                     "ListeningStatsStore", "MaerPlaylistCloudSync", "UserChoiceCloudSync",
                     "PlaybackClaimSync", "Artwork"] {
            #expect(code.contains(name), "\(name) ist nirgends: der Umzug ist unvollstaendig")
        }
        // The scene change asks the driving-mode clock for EVERY phase, even
        // `.inactive`, so it must not stand in one of the two branches.
        guard let driveMode = code.range(of: "DriveModeController"),
              let firstBranch = code.range(of: "case .active:") else {
            Issue.record("der Szenenwechsel wurde umgebaut"); return
        }
        #expect(driveMode.lowerBound < firstBranch.lowerBound,
                "die Fahrmodus-Uhr steht in einem Zweig und verpasst .inactive")
    }
}
#endif
