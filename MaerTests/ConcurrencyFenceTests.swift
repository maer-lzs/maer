// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The concurrency seam. Every escape from structured concurrency is a
/// counted site with a reason on the line itself or in the four lines
/// above it: `@unchecked Sendable` says "unchecked because", a
/// `DispatchQueue` says "queue because" (an API that hands over a queue
/// or wants a synchronous answer), a `Task.detached` says "detached
/// because", a `nonisolated(unsafe)` says "unsafe because". Comment lines
/// do not count. The stocks below are the count, both ways
/// (`StockDrift`); the `Task.sleep` stock is the inventory of the ticks,
/// waits and polls.
struct ConcurrencyFenceTests {

    /// Non-comment lines that name the token.
    nonisolated static func sites(of token: String, in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && trimmed.contains(token)
            }.count
    }

    /// Token lines whose reason marker is neither on the line nor within
    /// the four lines above it.
    nonisolated static func unreasoned(token: String, marker: String, in text: String) -> Int {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var count = 0
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), trimmed.contains(token) else { continue }
            let window = lines[max(0, index - 4)...index]
            if !window.contains(where: { $0.contains(marker) }) { count += 1 }
        }
        return count
    }

    nonisolated static let uncheckedStock: [String: Int] = ["PlayerViewModel.swift": 1]
    // BESTAND OHNE EINZELGRUENDE: der Grund steht AM FUNDORT ("queue because") und wird vom
    // Fall darunter erzwungen; ein Abbild hier waere eine zweite Stelle zum
    // Abdriften.
    nonisolated static let queueStock: [String: Int] = ["PlayerViewModel.swift": 1, "PlayerViewModel+NowPlaying.swift": 1, "NetworkStatus.swift": 1, "NetworkMonitor.swift": 1]
    // BESTAND OHNE EINZELGRUENDE: der Grund steht AM FUNDORT ("detached because") und wird vom
    // Fall darunter erzwungen.
    nonisolated static let detachedStock: [String: Int] = ["ImageCache.swift": 5, "LibraryViewModel.swift": 2, "DownloadManager.swift": 1, "PodcastImport.swift": 2, "Lyrics.swift": 2, "GPodderSync.swift": 2, "SubsonicClient.swift": 1, "SearchDoor.swift": 1, "RadioDiagnostics.swift": 1, "ProviderSearch.swift": 1, "PodcastSections.swift": 1, "LocalProvider.swift": 1, "ListeningStats.swift": 1, "LibriVoxImporter.swift": 1, "JellyfinClient.swift": 1, "APIClient.swift": 1, "ListenHistory.swift": 2]
    // BESTAND OHNE EINZELGRUENDE: der Grund steht AM FUNDORT ("unsafe because") und wird vom
    // Fall darunter erzwungen; gemessen am 27.09.2026, 18 Stellen in 8 Dateien, seit
    // `ServerTimestamp` 15 in 6, seit dem Zuhoerer je Bestand 13 in 6.
    nonisolated static let unsafeStock: [String: Int] = ["PlayerViewModel.swift": 5, "ListeningStore.swift": 2, "FileDownloader.swift": 3, "ForeignMarks.swift": 1, "PodcastRefreshService.swift": 1, "SQLiteConnection.swift": 1]
    // BESTAND OHNE EINZELGRUENDE: ein reines Inventar der Ticks, Warten und Polls ueber 30
    // Dateien; hier gibt es keinen Marker am Fundort, und 30 abgeschriebene
    // Saetze waeren 30 Stellen zum Abdriften.
    nonisolated static let sleepStock: [String: Int] = ["Retry.swift": 2, "HostCourtesy.swift": 1, "LibraryView.swift": 1, "BottomBarState.swift": 3, "UITestSeed.swift": 2, "PodcastsView.swift": 2, "PlayerViewModel+Sync.swift": 2, "PlayerViewModel.swift": 1, "PlaybackNotices.swift": 1, "SubsonicClient.swift": 1, "SourceBudget.swift": 1, "SearchModels.swift": 1, "TileDwell.swift": 1, "PodcastSubscriptions.swift": 1, "PodcastSourceView.swift": 1, "PodcastShowView.swift": 1, "PodcastServerSave.swift": 1, "StandCarrier.swift": 1, "PlayerViewModel+SleepTimer.swift": 1, "PlayerCoordinator.swift": 2, "NavigationBarNudge.swift": 1, "MusicViewModel.swift": 1, "MusicView.swift": 1, "MusicPageBody.swift": 1, "GPodderClient.swift": 1, "GlobalSearchModel.swift": 1, "DriveMode.swift": 1, "Artwork.swift": 1, "AuthViewModel.swift": 1]

    /// Every file against a stock: no file may hold more sites than the
    /// stock names, and each site carries its marker.
    static func offenders(token: String, marker: String?, stock: [String: Int]) throws -> [String] {
        var out: [String] = []
        var seen: Set<String> = []
        var counts: [String: Int] = [:]
        for file in ProjectFileIntegrityTests.sourceFiles() {
            seen.insert(file.lastPathComponent)
            let text = try String(contentsOf: file, encoding: .utf8)
            counts[file.lastPathComponent, default: 0] += Self.sites(of: token, in: text)
            if let marker, Self.unreasoned(token: token, marker: marker, in: text) > 0 {
                out.append("\(file.lastPathComponent): without \"\(marker)\"")
            }
        }
        out += StockDrift.findings(counts: counts, stock: stock)
        // A stock entry for a file that is gone is a claim about nothing and
        // stayed green when the file left (17.09.2026).
        for ghost in stock.keys.filter({ !seen.contains($0) }).sorted() {
            out.append("\(ghost): named in the stock, but gone")
        }
        return out
    }

    @Test("@unchecked Sendable nur mit Grund und nur im Bestand", .needsTheSources)
    func uncheckedSendableIsCountedAndReasoned() throws {
        let offenders = try Self.offenders(token: "@unchecked Sendable", marker: "unchecked because", stock: Self.uncheckedStock)
        #expect(offenders.isEmpty, "unchecked past the fence: \(offenders)")
        #expect(Self.sites(of: "@unchecked Sendable", in: "// not @unchecked Sendable\nfinal class A: @unchecked Sendable {}") == 1)
        #expect(Self.unreasoned(token: "@unchecked Sendable", marker: "unchecked because", in: "final class A: @unchecked Sendable {}") == 1)
        #expect(Self.unreasoned(token: "@unchecked Sendable", marker: "unchecked because", in: "/// unchecked because one lock guards it\n///\n///\n///\nfinal class A: @unchecked Sendable {}") == 0)
        #expect(Self.unreasoned(token: "@unchecked Sendable", marker: "unchecked because", in: "/// unchecked because far above\n///\n///\n///\n///\nfinal class A: @unchecked Sendable {}") == 1)
    }

    @Test("DispatchQueue nur, wo eine API eine Queue verlangt, mit Grund und im Bestand", .needsTheSources)
    func dispatchQueueIsCountedAndReasoned() throws {
        let offenders = try Self.offenders(token: "DispatchQueue", marker: "queue because", stock: Self.queueStock)
        #expect(offenders.isEmpty, "DispatchQueue past the fence: \(offenders)")
        #expect(Self.unreasoned(token: "DispatchQueue", marker: "queue because", in: "DispatchQueue.main.async { work() }") == 1)
        #expect(Self.unreasoned(token: "DispatchQueue", marker: "queue because", in: "// queue because the API wants one\nmonitor.start(queue: DispatchQueue.global())") == 0)
    }

    @Test("Task.detached traegt einen Grund, und der Bestand darf nur fallen", .needsTheSources)
    func detachedIsCountedAndReasoned() throws {
        let offenders = try Self.offenders(token: "Task.detached", marker: "detached because", stock: Self.detachedStock)
        #expect(offenders.isEmpty, "detached past the fence: \(offenders)")
        #expect(Self.unreasoned(token: "Task.detached", marker: "detached because", in: "Task.detached { work() }") == 1)
        #expect(Self.unreasoned(token: "Task.detached", marker: "detached because", in: "// detached because the write must finish\nTask.detached { work() }") == 0)
    }

    @Test("nonisolated(unsafe) traegt einen Grund, und der Bestand darf nur fallen", .needsTheSources)
    func unsafeIsCountedAndReasoned() throws {
        let offenders = try Self.offenders(token: "nonisolated(unsafe)", marker: "unsafe because", stock: Self.unsafeStock)
        #expect(offenders.isEmpty, "nonisolated(unsafe) past the fence: \(offenders)")
        #expect(Self.unreasoned(token: "nonisolated(unsafe)", marker: "unsafe because",
                                in: "nonisolated(unsafe) static var hook: (() -> Void)?") == 1)
        #expect(Self.unreasoned(token: "nonisolated(unsafe)", marker: "unsafe because",
                                in: "// unsafe because set once at start\nnonisolated(unsafe) static var hook: (() -> Void)?") == 0)
        #expect(Self.sites(of: "nonisolated(unsafe)", in: "/// `nonisolated(unsafe)` in a doc comment\nlet x = 1") == 0,
                "a comment that names it is no site")
    }

    @Test("Task.sleep-Stellen (Ticks, Warten, Polls) sind inventarisiert und werden nur weniger", .needsTheSources)
    func sleepSitesOnlyShrink() throws {
        let offenders = try Self.offenders(token: "Task.sleep", marker: nil, stock: Self.sleepStock)
        #expect(offenders.isEmpty, "sleep sites past the inventory: \(offenders)")
        #expect(Self.sites(of: "Task.sleep", in: "try? await Task.sleep(for: .seconds(1))\n// Task.sleep in a comment") == 1)
    }

    /// Guards that check a flag the file sets to `true` and wait in the
    /// same condition. Between the check and the set a second caller finds
    /// the flag still down; only the approachable-concurrency setting kept
    /// the door from suspending there.
    ///
    /// The bound, measured: the second shape (check, then an `await` of its
    /// own, then set or act) is not read. Taken at its form it found twelve
    /// sites, all of them flags that say a run ENDED (`reachedEnd`,
    /// `shelvesLoaded`, `fellBack`), each beside an in-flight flag set
    /// before the first suspension; the form does not tell the two kinds
    /// apart. A check on state the function does not set is not read either;
    /// the fence knows no such site, and the one known by hand, the cached
    /// render (`entries.isEmpty`), asks after its last suspension whether a
    /// load of this process began (`loadsBegun == 0`), witnessed in
    /// `ColdStartCacheTests` for all three orders.
    nonisolated static func flagChecksAcrossAwait(in text: String) throws -> [String] {
        let code = SyncContractFenceTests.stripped(text)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let whole = NSRange(code.startIndex..., in: code)
        let setter = try NSRegularExpression(pattern: "([A-Za-z_][A-Za-z0-9_]*) = true")
        let flags = Set(setter.matches(in: code, range: whole).compactMap {
            Range($0.range(at: 1), in: code).map { String(code[$0]) }
        })
        let guards = try NSRegularExpression(pattern: "guard ([^{}]*?) else \\{")
        var found: [String] = []
        for match in guards.matches(in: code, range: whole) {
            guard let range = Range(match.range(at: 1), in: code) else { continue }
            let condition = String(code[range])
            guard condition.contains("await ") else { continue }
            for flag in flags.sorted()
            where condition.range(of: "!(self\\.)?\(flag)(?![A-Za-z0-9_])", options: .regularExpression) != nil {
                found.append(flag)
            }
        }
        return found
    }

    @Test("kein Merker wird geprueft, waehrend dieselbe Bedingung wartet", .needsTheSources)
    func noFlagIsCheckedAcrossAnAwait() throws {
        var offenders: [String] = []
        var read = 0
        for file in ProjectFileIntegrityTests.sourceFiles() {
            read += 1
            let text = try String(contentsOf: file, encoding: .utf8)
            for flag in try Self.flagChecksAcrossAwait(in: text) {
                offenders.append("\(file.lastPathComponent): \(flag)")
            }
        }
        #expect(read > 0, "the fence read no source")
        #expect(offenders.isEmpty, "a flag checked across an await: \(offenders)")
        // The calibration lines: the old form is found, also over lines and
        // with a receiver; the healed form and a flag the file never sets are not.
        let old = "guard !loaded, !loading, await Reachability.isConnected() else { return }\nloading = true"
        #expect(try Self.flagChecksAcrossAwait(in: old) == ["loading"])
        let spread = "guard\n  !self.isLoading,\n  await ready()\nelse { return }\nself.isLoading = true"
        #expect(try Self.flagChecksAcrossAwait(in: spread) == ["isLoading"])
        let healed = "guard !loaded, !loading else { return }\nloading = true\nguard await Reachability.isConnected() else { return }"
        #expect(try Self.flagChecksAcrossAwait(in: healed).isEmpty)
        #expect(try Self.flagChecksAcrossAwait(in: "guard !done, await ready() else { return }").isEmpty)
    }
}
#endif
