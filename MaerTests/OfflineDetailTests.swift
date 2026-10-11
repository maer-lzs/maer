// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// What is downloaded is complete offline on its page, a failure speaks a
/// sentence and never a type name, and the playlist card says what is on
/// the device like every tile.
struct OfflineDetailTests {
    /// Comments out, whitespace runs squeezed to one space: the fences look
    /// for CALLS, and a formatter's line break must not tear them.
    private static func squeezed(_ raw: String) -> String {
        SyncContractFenceTests.stripped(raw)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return squeezed(try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8))
    }

    // MARK: - The detail page

    @Test("Detailseite: das Geladene zeigt sich sofort, offline ohne Frage ans Netz, ohne Geladenes offline ein eigener Satz")
    func theStoreComesFirst() {
        #expect(DetailLoadPlan.decide(hasStored: true, isConnected: false) == .stored(refresh: false),
                "the downloaded playlist offline: its tracks, no request")
        #expect(DetailLoadPlan.decide(hasStored: true, isConnected: true) == .stored(refresh: true))
        #expect(DetailLoadPlan.decide(hasStored: false, isConnected: true) == .network)
        #expect(DetailLoadPlan.decide(hasStored: false, isConnected: false) == .offlineMissing,
                "flight mode is not a broken connection")
    }

    @Test("Detailseite: sie liest den Speicher des Downloads, und ein gescheiterter Abgleich nimmt nichts weg")
    func thePageReadsTheStore() throws {
        let page = try Self.source("Sources/Views/Music/MusicAlbumView.swift")
        #expect(page.contains("let stored = albumDownloads.loadCachedDetail(forItemId: item.id)"))
        #expect(page.contains("let plan = DetailLoadPlan.decide(hasStored: stored != nil, isConnected: isOnline)"), "the online value the root hands down, not the monitor")
        #expect(page.contains("guard plan == .network else {"),
                "a failed refresh keeps the stored detail instead of a failure page")
        #expect(page.contains("case .offlineMissing: loadFailure = .offline"))
        #expect(page.contains("Label(\"Not available offline\""))
        // No description repeats its title: the old one said "could not be
        // loaded" under "Couldn't load tracks".
        #expect(!page.contains("This could not be loaded. Check your connection."))
    }

    // MARK: - The sentence

    @Test("Satz: ein Server-Fehler nennt sich mit seinem Satz, ein Typname erreicht nie eine Seite")
    func noTypeNameInASentence() {
        struct OddFailure: Error {}
        let server = FreeCatalog.failureReason(SubsonicClient.SubsonicError.network, online: true)
        #expect(server == SubsonicClient.SubsonicError.network.errorDescription,
                "was \"SubsonicError\" in GT-8")
        #expect(server?.contains("SubsonicError") == false)
        let odd = FreeCatalog.failureReason(OddFailure(), online: true)
        #expect(odd != nil, "a real failure stays named")
        #expect(odd?.contains("OddFailure") == false)
        // A measured reason reaches the page as a sentence, its code the log.
        #expect(FreeCatalog.failureReason(APIError.http(503, "down"), online: true) == String(localized: "The source did not answer."))
        #expect(FreeCatalog.failureReason(CancellationError(), online: true) == nil)
    }

    // MARK: - The playlist card

    @Test("Playlist-Karte: offline spielbar, sobald etwas davon hier ist; geladen erst, wenn alles hier ist")
    func theCardSaysWhatIsHere() {
        #expect(PlaylistPresentation.downloadState(downloaded: [true])
                == .init(anyHere: true, allHere: true), "the downloaded server list \"Fragile\"")
        #expect(PlaylistPresentation.downloadState(downloaded: [false])
                == .init(anyHere: false, allHere: false), "\"Bach\", not downloaded")
        #expect(PlaylistPresentation.downloadState(downloaded: [true, false])
                == .init(anyHere: true, allHere: false), "a Mär list with some entries here")
        #expect(PlaylistPresentation.downloadState(downloaded: [])
                == .init(anyHere: false, allHere: false), "an empty list plays nothing and is not downloaded")
    }

    @Test("Playlist-Karte: sie traegt die Leiste jeder Kachel, und beide Welten nennen, was geladen sein muss")
    func theCardWearsTheTileScope() throws {
        let card = try Self.source("Sources/Views/Music/PlaylistCard.swift")
        #expect(card.contains("MediaAvailabilityScope(itemId: source.id, anyOf: source.downloadIds) { unavailable, allHere in"))
        #expect(card.contains(".offlineUnavailableBadge(unavailable)"))
        #expect(card.contains("if allHere { PlaylistDownloadedMark() }"))
        // The scope observes and hands `allHere` down: neither the card nor
        // the mark holds a grip on the downloader.
        #expect(!card.contains("DownloadManager"), "the card reads no download state itself")
        let scope = try Self.source("Sources/Views/MediaAvailabilityScope.swift")
        #expect(scope.contains("anyOf.map { downloadManager.downloadState(of: $0) }"))
        #expect(scope.contains("several?.allHere ?? false"))
        #expect(card.contains("downloadIds: [itemId])"), "a server list downloads as one")
        #expect(card.contains("downloadIds: list.itemIds)"), "a Mär list is its entries")
    }

    // MARK: - A refresh takes nothing away

    @Test("Abgleich: eine leere Antwort ersetzt kein gespeichertes Detail mit Titeln")
    func anEmptyRefreshKeepsTheStore() throws {
        #expect(!DetailLoadPlan.adopts(fetchedTrackCount: 0, storedTrackCount: 12),
                "the downloaded playlist whose server answers empty for a moment")
        #expect(DetailLoadPlan.adopts(fetchedTrackCount: 11, storedTrackCount: 12), "a real change is taken")
        #expect(DetailLoadPlan.adopts(fetchedTrackCount: 0, storedTrackCount: nil), "nothing stored: empty is the truth")
        #expect(DetailLoadPlan.adopts(fetchedTrackCount: 0, storedTrackCount: 0))
        let page = try Self.source("Sources/Views/Music/MusicAlbumView.swift")
        let ask = try #require(page.range(of: "guard DetailLoadPlan.adopts(fetchedTrackCount: list.chapters.count,"))
        let set = try #require(page.range(of: "detail = fetched"))
        #expect(ask.lowerBound < set.lowerBound, "the rule is asked before the answer replaces anything")
    }

    // MARK: - The log keeps its reason

    @Test("Log: der Grund im Log ist die Art des Fehlers, nie ein uebersetzter Satz")
    func theLogKeepsTheKindOfFailure() {
        struct OddFailure: Error {}
        let server = SubsonicClient.SubsonicError.network
        #expect(FreeCatalog.logReason(server) == FailureReason.of(server))
        #expect(FreeCatalog.logReason(server) != server.errorDescription, "a translated sentence tells nothing in a log")
        #expect(FreeCatalog.failureReason(server, online: true) == server.errorDescription, "the page keeps its sentence")
        #expect(FreeCatalog.logReason(OddFailure()) == FailureReason.of(OddFailure()))
        // The measured forms stay in the log, and nothing failed stays nil.
        #expect(FreeCatalog.logReason(APIError.http(429, "slow down")) == "HTTP 429")
        #expect(FreeCatalog.logReason(URLError(.timedOut)) == "URLError \(URLError.Code.timedOut.rawValue)")
        #expect(FreeCatalog.logReason(CancellationError()) == nil)
        #expect(FreeCatalog.logReason(FetchHeldBack()) == nil)
    }

    @Test("Log: die zwei Log-Leser fragen den Log-Grund")
    func theLogReadersAskTheLogReason() throws {
        let stock = try Self.source("Sources/ViewModels/CatalogStockService.swift")
        #expect(stock.contains("let technical = FreeCatalog.logReason(error) ?? FailureReason.of(error)"))
        let outcome = try Self.source("Sources/Models/CatalogLoadOutcome.swift")
        #expect(outcome.contains("FreeCatalog.logReason(error) ?? FailureReason.of(error)"))
        #expect(!outcome.contains("failureReason("))
        // Everywhere: no log line takes the page's sentence as its reason.
        var logLinesWithSentence: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
            for line in lines where line.contains("Logger.") && line.contains("failureReason(") {
                logLinesWithSentence.append(file.lastPathComponent)
            }
        }
        #expect(logLinesWithSentence.isEmpty, "log lines with the page sentence: \(logLinesWithSentence)")
    }
}
#endif
