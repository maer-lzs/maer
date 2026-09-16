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
/// ("tragbar, weil …") or is red: the stock below is the inventory of the
/// day the fence was built and may only shrink.
struct HTTPDoorFenceTests {

    /// Die Heimaten der Tuer, jede mit ihrem Grund IM Eintrag. Der Kopf
    /// nannte frueher drei davon als Datei und zwei als Typ, also genau die
    /// Form, in der eine Begruendung von ihrer Liste abdriftet.
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
    nonisolated static let reasonWordings = ["tragbar", "bearable, because"]

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

    @Test("URLSession nur hinter der HTTP-Tuer")
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

    /// The stock of `try?` without a reason in Networking and Providers on
    /// the day the fence was built. A file may only lose lines.
    // BESTAND OHNE EINZELGRUENDE: ein reines Inventar des Bautages ueber 46 Dateien, das
    // nur fallen darf. Warum ein einzelnes `try?` tragbar ist, gehoert laut
    // Inventar-Konvention an die Stelle selbst.
    nonisolated static let tryStock: [String: Int] = ["DownloadManager.swift": 33, "SubsonicProvider.swift": 23, "ImageCache.swift": 22, "JellyfinProvider.swift": 19, "LocalLibrary.swift": 17, "MaerPlaylists.swift": 12, "ABSPodcastProvider.swift": 10, "LibriVoxImporter.swift": 10, "PodcastSubscriptions.swift": 10, "RadioLogoService.swift": 10, "JellyfinClient.swift": 6, "PodcastRecommendationsStore.swift": 6, "SyncHistoryStore.swift": 6, "APIClient.swift": 5, "GPodderSync.swift": 5, "PlayQueue.swift": 5, "ArtistPortraitService.swift": 4, "CatalogStockStore.swift": 4, "GPodderClient.swift": 4, "PlaybackContext.swift": 4, "RadioArtworkService.swift": 4, "UserChoiceCloudSync.swift": 4, "BookmarkQueue.swift": 3, "FeedArtworkService.swift": 3, "FreeCatalogClients.swift": 3, "ResolutionCacheStore.swift": 3, "Retry.swift": 3, "CoverArtArchive.swift": 2, "ListeningStatsCloudSync.swift": 2, "PodcastRefreshService.swift": 2, "RSSProvider.swift": 2, "SubsonicClient.swift": 2, "SyncQueue.swift": 2, "CatalogShuffle.swift": 1, "CatalogStockFetch.swift": 1, "DeadCatalogItems.swift": 1, "FreeCatalogProvider.swift": 1, "OERRLiveStore.swift": 1, "PinchflatClient.swift": 1, "PodcastDirectory.swift": 1, "PodcastServerSave.swift": 1, "PodcastTranscript.swift": 1, "RadioDiagnostics.swift": 1, "RadioProvider.swift": 1, "SerializedWriteChain.swift": 1, "SourceBudget.swift": 1]

    @Test("try? in Networking und Providers traegt einen Grund, oder der Bestand schrumpft")
    func tryCarriesAReasonOrShrinks() throws {
        var grown: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles()
        where file.path.contains("/Sources/Networking/") || file.path.contains("/Sources/Providers/") {
            let count = Self.unreasonedTryLines(in: try String(contentsOf: file, encoding: .utf8))
            let allowed = Self.tryStock[file.lastPathComponent] ?? 0
            if count > allowed { grown.append("\(file.lastPathComponent): \(count) > \(allowed)") }
        }
        #expect(grown.isEmpty, "these files swallow more errors than the stock allows: \(grown)")
        #expect(Self.unreasonedTryLines(in: "let x = try? await fetch()") == 1)
        #expect(Self.unreasonedTryLines(in: "// tragbar, weil ein Cover ohne Bild kein Fehler ist\nlet x = try? await fetch()") == 0)
        #expect(Self.unreasonedTryLines(in: "let x = try? await fetch()   // tragbar, weil …") == 0)
        // `try?` is the keyword, not the tail of an identifier: a function
        // returning `…Entry?` is not a swallowed error.
        #expect(Self.unreasonedTryLines(in: "static func decode(_ d: Data) -> Foo.Entry? {") == 0)
    }
}
#endif
