// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// `URLSession` lives behind the HTTP door. The door itself (`HTTP.swift`,
/// the sessions in `URLSession+Maer.swift`, the policy in `Retry.swift`),
/// the background transfer session (`FileDownloader`, its own door for
/// downloads) and the app delegate's background-session hook are the homes;
/// everything else asks `HTTP`. Comment lines do not count. And a `try?`
/// on a network path in Networking or Providers carries a reason
/// ("tragbar, weil …") or is red: the stock below is the count, both ways
/// (`StockDrift`).
struct HTTPDoorFenceTests {

    /// The homes of the door, each with its reason IN the entry. The head
    /// used to name three of them as a file and two as a type, exactly the
    /// form in which a justification drifts away from its list.
    nonisolated static let homes: [(path: String, reason: String)] = [
        ("/HTTP.swift", "die Tuer selbst"),
        ("/URLSession+Maer.swift", "die Sitzungen, die die Tuer haelt"),
        ("/Retry.swift", "die Wiederhol-Leiter, die eine Anfrage erneut stellt"),
        ("/FileDownloader.swift", "laedt in eine Datei und braucht dafuer eine eigene Sitzung mit Delegat"),
        ("/MaerApp.swift", "der Haken des App-Delegaten fuer die Hintergrund-Sitzung"),
    ]

    nonisolated static func isAHome(_ path: String) -> Bool {
        homes.contains { path.hasSuffix($0.path) }
    }

    /// Lines that name the session itself (`URLSession.`, `URLSession(`,
    /// `: URLSession`) outside comments. A task type handed across
    /// (`URLSessionDownloadTask`) is not a session.
    nonisolated static func sessionSites(in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//")
                    && trimmed.range(of: "URLSession\\b", options: .regularExpression) != nil
            }.count
    }

    /// The two wordings that count as a reason. They are narrow on purpose:
    /// a fence that accepts any comment beside a `try?` accepts every
    /// `try?`, because there is always a comment nearby.
    ///
    /// **The English one exists because the comment rule says English.**
    /// This fence knew only the German `tragbar, weil`, so obeying the rule
    /// made the fence red and obeying the fence broke the rule; the two
    /// stood against each other for weeks, and a translated comment really
    /// did turn a run red once. Both are kept: the stock is full of the
    /// German form and rewriting it wholesale would be a change of hundreds
    /// of lines with no measurement behind it. New comments use the English
    /// one.
    /// Both are WORDINGS, not substrings. `tragbar` alone would also match
    /// a German comment about `uebertragbar`, which says nothing about a
    /// swallowed error; measured today at zero such sites, so this costs
    /// nothing and closes the hole before it opens. All 54 sites in stock
    /// carry the full wording.
    nonisolated static let reasonWordings = ["tragbar, weil", "bearable, because"]

    /// `try?` lines without a reason on the same or the previous line. The
    /// `try` must not be the tail of an identifier: a function that returns
    /// `…Entry?` carries the substring `try? ` inside `Entry? ` and is not a
    /// swallowed error (a substring is not the keyword).
    nonisolated static func unreasonedTryLines(in text: String) -> Int {
        func carriesAReason(_ line: String) -> Bool {
            reasonWordings.contains { line.contains($0) }
        }
        var count = 0
        var previous = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let current = String(line)
            if current.range(of: "(?<![A-Za-z0-9_])try\\? ", options: .regularExpression) != nil,
               !carriesAReason(current), !carriesAReason(previous) {
                count += 1
            }
            previous = current
        }
        return count
    }

    @Test("URLSession only behind the HTTP door", .needsTheSources)
    func onlyTheDoorNamesTheSession() throws {
        var offenders: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() where !Self.isAHome(file.path) {
            let count = Self.sessionSites(in: try String(contentsOf: file, encoding: .utf8))
            if count > 0 { offenders.append("\(file.lastPathComponent): \(count)") }
        }
        #expect(offenders.isEmpty, "these files reach the session past the door: \(offenders)")
        #expect(Self.sessionSites(in: "let (d, r) = try await URLSession.shared.data(for: request)") == 1)
        #expect(Self.sessionSites(in: "// URLSession follows redirects\nlet (d, r) = try await HTTP.data(for: request)") == 0)
        #expect(Self.sessionSites(in: "var currentTask: URLSessionDownloadTask?") == 0)
    }

    /// The stock of `try?` without a reason in Networking and Providers,
    /// measured; it is the count, a file below it is red as much as above.
    // BESTAND OHNE EINZELGRUENDE: a pure inventory over 32 files, equal to the
    // count. Why a single `try?` is bearable belongs at the spot itself,
    // by the inventory convention.
    nonisolated static let tryStock: [String: Int] = ["DownloadManager.swift": 16, "SubsonicProvider.swift": 13, "ImageCache.swift": 17, "JellyfinProvider.swift": 12, "LocalLibrary.swift": 13, "LibriVoxImporter.swift": 8, "JellyfinClient.swift": 6, "MaerPlaylists.swift": 6, "PodcastRecommendationsStore.swift": 5, "GPodderClient.swift": 4, "GPodderSync.swift": 4, "UserChoiceCloudSync.swift": 4, "BookmarkQueue.swift": 1, "CatalogStockStore.swift": 3, "PodcastSubscriptions.swift": 3, "ResolutionCacheStore.swift": 3, "APIClient.swift": 2, "ArtistPortraitService.swift": 2, "FreeCatalogClients.swift": 2, "PodcastRefreshService.swift": 2, "RSSProvider.swift": 2, "SubsonicClient.swift": 2, "CatalogShuffle.swift": 1, "DeadCatalogItems.swift": 1, "OERRLiveStore.swift": 1, "PinchflatClient.swift": 1, "PodcastDirectory.swift": 1, "PodcastServerSave.swift": 1, "PodcastTranscript.swift": 1, "RadioArtworkService.swift": 1, "Retry.swift": 1, "SourceBudget.swift": 1]

    @Test("try? in Networking and Providers carries a reason, or the stock shrinks", .needsTheSources)
    func tryCarriesAReasonOrShrinks() throws {
        var counts: [String: Int] = [:]
        var seen: Set<String> = []
        for file in ProjectFileIntegrityTests.sourceFiles()
        where file.path.contains("/Sources/Networking/") || file.path.contains("/Sources/Providers/") {
            seen.insert(file.lastPathComponent)
            counts[file.lastPathComponent, default: 0] += Self.unreasonedTryLines(in: try String(contentsOf: file, encoding: .utf8))
        }
        let drift = StockDrift.findings(counts: counts, stock: Self.tryStock)
        #expect(drift.isEmpty, "these files swallow more errors than the stock allows, or the stock is above the count: \(drift)")
        // A stock entry for a file that is gone is a claim about nothing,
        // and it stayed green when the file left (17.09.2026): the stock
        // must name only files that are still there.
        let ghosts = Self.tryStock.keys.filter { !seen.contains($0) }.sorted()
        #expect(ghosts.isEmpty, "the stock names files that are gone: \(ghosts)")
        #expect(Self.unreasonedTryLines(in: "let x = try? await fetch()") == 1)
        #expect(Self.unreasonedTryLines(in: "// tragbar, weil ein Cover ohne Bild kein Fehler ist\nlet x = try? await fetch()") == 0)
        #expect(Self.unreasonedTryLines(in: "let x = try? await fetch()   // tragbar, weil …") == 0)
        #expect(Self.unreasonedTryLines(in: "// bearable, because nothing is lost\nlet x = try? f()") == 0)
        // A bare substring is not a wording: a comment about `uebertragbar`
        // contains `tragbar` and must not pass as a reason.
        #expect(Self.unreasonedTryLines(in: "// uebertragbar, sagt aber nichts\nlet x = try? f()") == 1)
        // `try?` is the keyword, not the tail of an identifier: a function
        // returning `…Entry?` is not a swallowed error.
        #expect(Self.unreasonedTryLines(in: "static func decode(_ d: Data) -> Foo.Entry? {") == 0)
    }

    /// The stock of `try?` without a reason in the views, measured after
    /// the surfaces that showed a failure as empty were healed. It is the
    /// count; a new swallowed error in a view carries its reason at the line
    /// or is not written, and a healed one is written back.
    // BESTAND OHNE EINZELGRUENDE: a pure inventory over 20 files, equal to the
    // count; the reason of a single `try?` belongs at the spot itself.
    nonisolated static let viewTryStock: [String: Int] = ["Lyrics.swift": 7, "MusicViewModel.swift": 1, "RadioView.swift": 3, "AddToPlaylistSheet.swift": 4, "BookmarkMeasure.swift": 3, "BottomBarState.swift": 3, "LibraryView.swift": 1, "PodcastsView.swift": 2, "RadioStationDetailView.swift": 2, "BookFeaturedCard.swift": 1, "DriveMode.swift": 1, "FreeAudiobooksPage.swift": 1, "MusicBrowseViews.swift": 1, "MusicView.swift": 1, "NavigationBarNudge.swift": 1, "PlayQueueView.swift": 1, "PodcastShowView.swift": 1, "PodcastSourceView.swift": 1, "RadioComponents.swift": 1, "RadioGenreView.swift": 1]

    @Test("try? in the views carries a reason, or the stock shrinks", .needsTheSources)
    func viewTryCarriesAReasonOrShrinks() throws {
        var counts: [String: Int] = [:]
        var seen: Set<String> = []
        for file in ProjectFileIntegrityTests.sourceFiles() where file.path.contains("/Sources/Views/") {
            seen.insert(file.lastPathComponent)
            counts[file.lastPathComponent, default: 0] += Self.unreasonedTryLines(in: try String(contentsOf: file, encoding: .utf8))
        }
        #expect(seen.contains("LibraryView.swift"), "the finder does not see the views")
        let drift = StockDrift.findings(counts: counts, stock: Self.viewTryStock)
        #expect(drift.isEmpty, "these views swallow more errors than the stock allows, or the stock is above the count: \(drift)")
        let ghosts = Self.viewTryStock.keys.filter { !seen.contains($0) }.sorted()
        #expect(ghosts.isEmpty, "the stock names views that are gone: \(ghosts)")
    }
}
#endif
