// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The one channel of playback notices: which notice shows as the pill, how
/// long, what stays behind it, and the log of all of them.
@MainActor
struct PlaybackNoticesTests {
    private func channel(expiry: Double = 0.2) -> (PlaybackNotices, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notices-\(UUID().uuidString)")
        return (PlaybackNotices(expirySeconds: expiry, ablage: Ablage(directory: folder)), folder)
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @Test("jeder Fall hat seine Zeile: Sync-Infos nur ins Protokoll, Spruenge kurz, Konflikt kurz als Fehler, Halt-Fehler bis Play")
    func everyCaseHasItsRow() {
        typealias Row = (pops: Bool, holds: Bool, error: Bool)
        let table: [PlaybackNotice.Kind: Row] = [
            .saved: (false, false, false), .queued: (false, false, false), .offline: (false, false, false),
            .serverAdopted: (true, false, false), .localUsed: (true, false, false),
            .conflict: (true, false, true), .downloadUnreadable: (true, false, true),
            .trackFailed: (true, true, true), .streamFailed: (true, true, true),
            .loadFailed: (true, true, true), .downloadUnreadableOffline: (true, true, true),
            .syncFailed: (true, false, true), .openFailed: (true, false, true), .cannotPlay: (true, true, true),
        ]
        #expect(Set(table.keys) == Set(PlaybackNotice.Kind.allCases), "a case without a row, or a row without a case")
        for (kind, row) in table {
            let answer = NoticeRule.answer(kind)
            #expect(answer == NoticeRule.Answer(pops: row.pops, holdsUntilPlay: row.holds, isError: row.error), "\(kind)")
        }
    }

    @Test("Sync-Infos poppen nicht auf und stehen doch im Protokoll")
    func syncInfosOnlyGoToTheLog() {
        let (notices, folder) = channel()
        defer { try? FileManager.default.removeItem(at: folder) }
        for notice in [PlaybackNotice.saved, .queued, .offline] { notices.show(notice, title: "Buch") }
        #expect(notices.shown == nil, "a sync info popped up")
        #expect(notices.log.map(\.kind) == [.saved, .queued, .offline])
        #expect(notices.log.allSatisfy { $0.title == "Buch" })
    }

    @Test("ein Fehler, der die Wiedergabe anhielt, bleibt ueber die kurze Frist hinaus und faellt erst bei Play")
    func aStoppingErrorHoldsUntilPlay() async {
        let (notices, folder) = channel()
        defer { try? FileManager.default.removeItem(at: folder) }
        notices.show(.loadFailed(.network), title: nil)
        await wait(0.5)
        #expect(notices.shown == .loadFailed(.network), "the stopping error went with the short notices")
        notices.played()
        #expect(notices.shown == nil)
        notices.show(.serverAdopted, title: nil)
        #expect(notices.shown == .serverAdopted)
        await wait(0.5)
        #expect(notices.shown == nil, "a short notice stayed")
    }

    @Test("eine Info nach einem Fehler ersetzt ihn nicht")
    func anInfoDoesNotReplaceAnError() {
        let (notices, folder) = channel(expiry: 60)
        defer { try? FileManager.default.removeItem(at: folder) }
        notices.show(.conflict, title: nil)
        notices.show(.serverAdopted, title: nil)
        #expect(notices.shown == .conflict)
        #expect(notices.log.map(\.kind) == [.conflict, .serverAdopted], "the info is not in the log")
    }

    @Test("ein kurzer Fehler ueber einem Halt-Fehler laesst ihn nach seiner Frist wieder sehen")
    func aHeldErrorReturnsAfterAShortOne() async {
        let (notices, folder) = channel()
        defer { try? FileManager.default.removeItem(at: folder) }
        notices.show(.loadFailed(.server), title: nil)
        notices.show(.conflict, title: nil)
        #expect(notices.shown == .conflict, "the precondition: the short error lies over the held one")
        await wait(0.5)
        #expect(notices.shown == .loadFailed(.server), "the player still stands, but the pill forgot why")
    }

    @Test("ein anderer Titel nimmt den Halt-Fehler des vorigen mit")
    func anotherTitleTakesTheHeldError() {
        let (notices, folder) = channel()
        defer { try? FileManager.default.removeItem(at: folder) }
        notices.show(.trackFailed, title: nil)
        notices.titleChanged()
        #expect(notices.shown == nil)
    }

    /// The error forms measured at a host that answers 401, 403, 404, 500,
    /// at a closed port and at a missing local file (AVPlayerItem.error).
    @Test("die Ursache eines Ladefehlers nach der gemessenen Form, ein unbekannter Fehler ist nicht das Netz")
    func theCauseOfALoadFailure() {
        func error(_ domain: String, _ code: Int, under: Int? = nil) -> NSError {
            let info: [String: Any] = under.map { [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: $0)] } ?? [:]
            return NSError(domain: domain, code: code, userInfo: info)
        }
        let table: [(String, NSError?, Bool, NoticeCause)] = [
            ("401", error(NSURLErrorDomain, -1013, under: -16840), true, .server),
            ("403", error("AVFoundationErrorDomain", -11849, under: -12873), true, .unknown),
            ("404", error(NSURLErrorDomain, -1100, under: -12938), true, .server),
            ("500", error(NSURLErrorDomain, -1008, under: -16847), true, .server),
            ("closed port", error(NSURLErrorDomain, -1004, under: -1004), true, .server),
            ("no internet", error(NSURLErrorDomain, -1009), true, .network),
            ("timeout", error(NSURLErrorDomain, -1001), true, .unknown),
            ("missing file", error("AVFoundationErrorDomain", -11800, under: -17913), true, .file),
            ("no error", nil, true, .unknown),
            ("offline, whatever it says", error(NSURLErrorDomain, -1008), false, .network),
        ]
        for (name, error, online, cause) in table {
            #expect(NoticeCause.of(error, online: online) == cause, "\(name)")
        }
        #expect(NoticeCause.network.icon == "wifi.exclamationmark")
        for cause in [NoticeCause.server, .file, .unknown] { #expect(cause.icon == "exclamationmark.triangle") }
        #expect(PlaybackNotice.loadFailed(.unknown).icon == "exclamationmark.triangle", "not knowing drew the network")
    }

    @Test("das Protokoll liegt auf der Platte, ein neuer Start liest es, alte und zu viele Zeilen fallen")
    func theLogLastsAndStaysSmall() async {
        let (notices, folder) = channel()
        defer { try? FileManager.default.removeItem(at: folder) }
        notices.show(.conflict, title: "A")
        await notices.awaitPendingSave()
        let again = PlaybackNotices(ablage: Ablage(directory: folder))
        #expect(again.log.map(\.kind) == [.conflict], "a restart lost the log")
        let now = 1_000_000_000.0
        func entry(_ at: Double) -> NoticeLogEntry {
            NoticeLogEntry(id: UUID(), at: at, kind: .saved, label: "", icon: "", title: nil)
        }
        let old = entry(now - NoticeLogEntry.maxAge - 1)
        let kept = NoticeLogEntry.trimmed([old, entry(now - 10)], now: now)
        #expect(kept.count == 1 && kept.first?.at == now - 10, "an entry older than the limit stayed")
        let many = (0..<(NoticeLogEntry.limit + 5)).map { entry(now - Double($0)) }.reversed()
        #expect(NoticeLogEntry.trimmed(Array(many), now: now).count == NoticeLogEntry.limit)
    }

    @Test("jeder Start der Wiedergabe laesst den Halt-Fehler fallen, auch von Sperrbildschirm und Kopfhoerern")
    func everyStartLetsTheStoppingErrorFall() throws {
        let id = "rss:notice-start:\(UUID().uuidString)"
        let media = LibraryItemMedia(metadata: nil, duration: 100, chapters: nil, tracks: nil)
        let (notices, folder) = channel(expiry: 60)
        defer { try? FileManager.default.removeItem(at: folder) }
        let coordinator = PlayerCoordinator(provider: MockProvider(), notices: notices)
        coordinator._seedActivePlayerForUITest(item: LibraryItem(id: id, media: media, addedAt: nil),
                                               detail: LibraryItemDetail(id: id, media: media, userMediaProgress: nil),
                                               chapters: [], currentChapterIndex: 0, isFallback: false)
        let model = try #require(coordinator.viewModel)
        model.showSourceHint(.loadFailed(.network))
        #expect(notices.shown == .loadFailed(.network), "the precondition: the stopping error stands")
        model.play(caller: "remote")
        #expect(notices.shown == nil, "a start did not let the stopping error fall")
        model.pause()
    }

    @Test("jeder Start geht durch play(), und die Fernbedienung ruft es", .needsTheSources)
    func everyStartGoesThroughPlay() throws {
        let root = SourceTree.root
        let model = SyncContractFenceTests.stripped(try String(contentsOf: root.appendingPathComponent("Sources/ViewModels/PlayerViewModel.swift"), encoding: .utf8))
        #expect(model.components(separatedBy: "notePlayback(\"play\"").count - 1 == 1, "a second start beside play()")
        #expect(model.contains("playbackStarts.send()"))
        let remote = SyncContractFenceTests.stripped(try String(contentsOf: root.appendingPathComponent("Sources/ViewModels/PlayerViewModel+NowPlaying.swift"), encoding: .utf8))
        #expect(remote.contains("self?.play()"), "the remote command starts past play()")
    }

    @Test("das Protokoll reist nicht: sein Dokument steht in keinem Traeger und keiner Wahl", .needsTheSources)
    func theLogDoesNotTravel() throws {
        let files = ProjectFileIntegrityTests.sourceTexts(in: ["Sources"])
        #expect(files.count > 100, "the fence did not read the sources")
        let naming = files.filter { $0.text.contains("documentName") && $0.text.contains("PlaybackNotices") }.map(\.name)
        #expect(naming == ["PlaybackNotices.swift"], "\(naming)")
        let literal = files.filter { $0.text.contains("\"playback-notices\"") }.map(\.name)
        #expect(literal == ["PlaybackNotices.swift"], "the document is named elsewhere: \(literal)")
    }

    @Test("eine Meldung aus dem Laden kommt an, obwohl das Modell erst danach am Koordinator haengt")
    func aNoticeOfTheLoadArrives() throws {
        let id = "rss:notice-load:\(UUID().uuidString)"
        let media = LibraryItemMedia(metadata: nil, duration: 100, chapters: nil, tracks: nil)
        let (notices, folder) = channel(expiry: 60)
        defer { try? FileManager.default.removeItem(at: folder) }
        let coordinator = PlayerCoordinator(provider: MockProvider(), notices: notices)
        coordinator._seedActivePlayerForUITest(item: LibraryItem(id: id, media: media, addedAt: nil),
                                               detail: LibraryItemDetail(id: id, media: media, userMediaProgress: nil),
                                               chapters: [], currentChapterIndex: 0, isFallback: false,
                                               noticeBeforeAttach: .localUsed)
        #expect(notices.shown == .localUsed, "a notice said during the load was lost at the attach")
        #expect(notices.log.map(\.kind) == [.localUsed])
    }

    @Test("ein Titel ohne Spur sagt es ueber dem Mini-Player, bis zum naechsten Start")
    func aTitleThatCannotPlaySaysSo() async {
        let id = "rss:notice-cannot:\(UUID().uuidString)"
        let detail = LibraryItemDetail(id: id, media: LibraryItemMedia(metadata: nil, duration: 100, chapters: nil, tracks: nil),
                                       userMediaProgress: nil)
        let model = PlayerViewModel(provider: MockProvider())
        await model.load(item: detail)
        #expect(model.sourceHint?.kind == .cannotPlay, "the load error stayed in the full player only")
        #expect(model.errorMessage == model.sourceHint?.label, "pill and full player say different sentences")
        #expect(NoticeRule.answer(.cannotPlay).holdsUntilPlay)
    }

    @Test("ein gescheitertes Oeffnen ist die Pille des Kanals, der grosse Player zeigt denselben Satz")
    func aFailedOpenIsThePill() {
        let (notices, folder) = channel(expiry: 60)
        defer { try? FileManager.default.removeItem(at: folder) }
        let coordinator = PlayerCoordinator(provider: MockProvider(), notices: notices)
        coordinator.sayOpenFailure("Offline. Nicht geladen.", cause: .network, title: "Buch")
        #expect(notices.shown == .openFailed("Offline. Nicht geladen.", .network))
        #expect(notices.shown?.icon == "wifi.exclamationmark")
        #expect(coordinator.loadError == "Offline. Nicht geladen.")
        #expect(notices.log.last?.title == "Buch")
    }

    @Test("Sync-Fehler und Oeffnen laufen durch den Kanal, keine eigene Zeile mehr", .needsTheSources)
    func syncAndOpenGoThroughTheChannel() throws {
        let root = SourceTree.root
        let sync = SyncContractFenceTests.stripped(try String(contentsOf: root.appendingPathComponent("Sources/ViewModels/PlayerViewModel+Sync.swift"), encoding: .utf8))
        #expect(sync.components(separatedBy: "if syncStatus != .failed { showSourceHint(.syncFailed) }").count - 1 == 2,
                "a sync failure that says nothing over the mini bar, or says it on every round")
        let library = SyncContractFenceTests.stripped(try String(contentsOf: root.appendingPathComponent("Sources/Views/LibraryView.swift"), encoding: .utf8))
        #expect(!library.contains("playerCoordinator.loadError"), "the library shows a failed open on a line of its own")
    }
}
#endif
