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
            .waitingForNetwork: (true, true, false),
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

    @Test("ein Fehler, der die Wiedergabe anhielt: die Pille geht nach der kurzen Frist, der Fehler bleibt gehalten und faellt erst bei Play")
    func aStoppingErrorHoldsUntilPlay() async {
        let (notices, folder) = channel()
        defer { try? FileManager.default.removeItem(at: folder) }
        notices.show(.loadFailed(.network), title: nil)
        #expect(notices.shown == .loadFailed(.network) && notices.held == .loadFailed(.network))
        await wait(0.5)
        #expect(notices.shown == nil, "the pill of a stopping error stood past the short time")
        #expect(notices.held == .loadFailed(.network), "the stopping error went with its pill")
        notices.played()
        #expect(notices.shown == nil && notices.held == nil, "a start did not let the stopping error fall")
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

    @Test("ein kurzer Fehler ueber einem Halt-Fehler: nach seiner Frist ist die Pille leer, der Halt-Fehler bleibt gehalten")
    func aHeldErrorOutlastsAShortOne() async {
        let (notices, folder) = channel()
        defer { try? FileManager.default.removeItem(at: folder) }
        notices.show(.loadFailed(.server), title: nil)
        notices.show(.conflict, title: nil)
        #expect(notices.shown == .conflict, "the precondition: the short error lies over the held one")
        await wait(0.5)
        #expect(notices.shown == nil, "a held error came back as the pill")
        #expect(notices.held == .loadFailed(.server), "the player still stands, but the channel forgot why")
    }

    @Test("ein anderer Titel nimmt den Halt-Fehler des vorigen mit")
    func anotherTitleTakesTheHeldError() {
        let (notices, folder) = channel()
        defer { try? FileManager.default.removeItem(at: folder) }
        notices.show(.trackFailed, title: nil)
        notices.titleChanged()
        #expect(notices.shown == nil && notices.held == nil)
    }

    /// Every held error alike: its pill goes after the short time, then the
    /// error stands outside the pill (the bar's second line, the line under
    /// the full player's controls) until the next start or change of title.
    /// Only the wait keeps its pill.
    @Test("jeder Halt-Fehler: Pille kurz, danach steht er ausserhalb der Pille bis zum naechsten Start oder Titelwechsel; nur das Warten haelt die Pille")
    func everyHeldErrorLeavesThePillAndStaysHeld() {
        let held: [PlaybackNotice] = [.trackFailed, .streamFailed, .loadFailed(.network), .downloadUnreadableOffline,
                                      .cannotPlay("Kein Titel")]
        #expect(Set(held.map(\.kind)) == Set(PlaybackNotice.Kind.allCases.filter {
            NoticeRule.answer($0).holdsUntilPlay && NoticeRule.answer($0).isError
        }), "the list of held errors is not the rule's")
        for notice in held {
            let answer = NoticeRule.answer(notice.kind)
            #expect(answer.pillExpires, "\(notice.kind) keeps its pill")
            let shown = NoticeRule.next(NoticeRule.State(), .show(notice))
            #expect(NoticePlacement.heldOutsidePill(shown: shown.shown, held: shown.held) == nil,
                    "\(notice.kind) stands twice while its pill shows")
            let after = NoticeRule.next(shown, .expired(notice))
            #expect(after == NoticeRule.State(shown: nil, held: notice), "\(notice.kind) after its time: \(after)")
            #expect(NoticePlacement.heldOutsidePill(shown: after.shown, held: after.held) == notice,
                    "\(notice.kind) said nothing after its pill")
            // An info and the wait push aside no held error, not even one
            // whose pill is gone.
            for info in [PlaybackNotice.serverAdopted, .waitingForNetwork] {
                #expect(NoticeRule.next(after, .show(info)) == after, "\(info.kind) pushed \(notice.kind) aside")
            }
            #expect(NoticeRule.next(after, .streamResumed) == after, "the stream running again took \(notice.kind)")
            for event in [NoticeRule.Event.played, .titleChanged] {
                let gone = NoticeRule.next(after, event)
                #expect(gone == NoticeRule.State(), "\(notice.kind) stayed over \(event)")
                #expect(NoticePlacement.heldOutsidePill(shown: gone.shown, held: gone.held) == nil)
            }
            #expect(notice.barWords != nil, "\(notice.kind) has no words for the bar")
        }
        // Only held errors have words for the bar.
        let others: [PlaybackNotice] = [.saved, .serverAdopted, .localUsed, .queued, .offline, .conflict,
                                        .downloadUnreadable, .syncFailed, .openFailed("x", .network), .waitingForNetwork]
        #expect(Set(others.map(\.kind)).union(held.map(\.kind)) == Set(PlaybackNotice.Kind.allCases))
        for notice in others { #expect(notice.barWords == nil, "\(notice.kind) speaks on the bar") }
        let wait = NoticeRule.answer(.waitingForNetwork)
        #expect(!wait.pillExpires, "the wait lost its pill")
        let waiting = NoticeRule.next(NoticeRule.State(), .show(.waitingForNetwork))
        #expect(NoticeRule.next(waiting, .expired(.waitingForNetwork)) == waiting)
        #expect(NoticePlacement.heldOutsidePill(shown: nil, held: .waitingForNetwork) == nil, "the wait stood on the bar")
        // A short notice over the wait gives the pill back to it.
        let over = NoticeRule.next(waiting, .show(.serverAdopted))
        #expect(NoticeRule.next(over, .expired(.serverAdopted)).shown == .waitingForNetwork)
    }

    /// The bar says the held error from the channel alone: the one
    /// placement, the channel's two values, no second rule beside it.
    @Test("die Leiste sagt den Halt-Fehler aus dem Kanal, ueber die eine Platzierung, und nirgends sonst", .needsTheSources)
    func theBarSaysTheHeldErrorFromTheChannel() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let bar = try code("Sources/Views/MiniPlayerBar.swift")
        #expect(bar.contains("notices: coordinator.notices)"), "the bar's lines do not hear the channel")
        #expect(bar.contains("NoticePlacement.heldOutsidePill(shown: notices.shown, held: notices.held)"),
                "the bar decides the held error by a rule of its own")
        #expect(bar.contains("held.barWords"), "the bar does not say the held error's words")
        let files = ProjectFileIntegrityTests.sourceTexts(in: ["Sources"])
        let speaking = files.filter { $0.text.contains(".barWords") }.map(\.name)
        #expect(speaking == ["MiniPlayerBar.swift"], "the bar's words stand elsewhere: \(speaking)")
        let channel = try code("Sources/ViewModels/PlaybackNotices.swift")
        #expect(channel.contains("NoticeRule.answer(notice.kind).pillExpires"), "the channel times the pill by its own rule")
        #expect(channel.contains("if held != next.held { held = next.held }"), "the channel does not publish the held error")
    }

    @Test("die Woerter der Leiste stehen deutsch im Katalog", .needsTheSources)
    func theBarWordsStandInTheCatalog() throws {
        let data = try Data(contentsOf: SourceTree.root.appendingPathComponent("Sources/Localizable.xcstrings"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = try #require(json?["strings"] as? [String: Any], "the catalog was not read")
        func german(_ key: String) -> String? {
            let entry = strings[key] as? [String: Any]
            let unit = ((entry?["localizations"] as? [String: Any])?["de"] as? [String: Any])?["stringUnit"] as? [String: Any]
            return unit?["value"] as? String
        }
        let words: [(String, String)] = [
            ("track unavailable", "Titel nicht verfügbar"), ("not reachable", "nicht erreichbar"),
            ("not loaded", "nicht geladen"), ("download unreadable", "Download nicht lesbar"),
            ("cannot play", "kann nicht wiedergeben"),
        ]
        for (key, value) in words { #expect(german(key) == value, "\(key) says \(String(describing: german(key)))") }
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

    /// The real attach: a title that cannot play says so over the change of
    /// title that brings it, and the next title takes that error with it.
    @Test("der Halt-Fehler aus dem Laden ueberlebt den Titelwechsel, der ihn bringt; der naechste Titel nimmt ihn mit")
    func aStoppingErrorOfTheLoadOutlivesTheChange() throws {
        let media = LibraryItemMedia(metadata: nil, duration: 100, chapters: nil, tracks: nil)
        let (notices, folder) = channel(expiry: 60)
        defer { try? FileManager.default.removeItem(at: folder) }
        let coordinator = PlayerCoordinator(provider: MockProvider(), notices: notices)
        func seed(_ id: String, _ notice: PlaybackNotice?) {
            coordinator._seedActivePlayerForUITest(item: LibraryItem(id: id, media: media, addedAt: nil),
                                                   detail: LibraryItemDetail(id: id, media: media, userMediaProgress: nil),
                                                   chapters: [], currentChapterIndex: 0, isFallback: false,
                                                   noticeBeforeAttach: notice)
        }
        seed("rss:notice-a:\(UUID().uuidString)", .cannotPlay("Kein Titel"))
        #expect(notices.shown == .cannotPlay("Kein Titel"), "the change of title swallowed its own stopping error")
        seed("rss:notice-b:\(UUID().uuidString)", nil)
        #expect(notices.shown == nil, "the previous title's stopping error stayed over the next title")
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

    @Test("ein Titel ohne Spur sagt es in der Pille bis zum naechsten Start, im grossen Player genau einmal")
    func aTitleThatCannotPlaySaysSo() async {
        let id = "rss:notice-cannot:\(UUID().uuidString)"
        let detail = LibraryItemDetail(id: id, media: LibraryItemMedia(metadata: nil, duration: 100, chapters: nil, tracks: nil),
                                       userMediaProgress: nil)
        let model = PlayerViewModel(provider: MockProvider())
        await model.load(item: detail)
        #expect(model.sourceHint?.kind == .cannotPlay, "the load error stayed in the full player only")
        let line = model.errorMessage
        #expect(line == nil, "the full player says the sentence twice, in the pill and on the line: \(String(describing: line))")
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

    /// A sync failure lasts beyond its pill: both failure sites set the line
    /// under the controls before they say the pill, the full player shows
    /// that line, and the channel, whose pill goes after its time, never
    /// touches it.
    @Test("ein andauernder Sync-Fehler steht nach der Pille weiter als Zeile im grossen Player", .needsTheSources)
    func aLastingSyncFailureStaysAsTheLine() throws {
        let root = SourceTree.root
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8))
        }
        let sync = try code("Sources/ViewModels/PlayerViewModel+Sync.swift")
        let pill = "if syncStatus != .failed { showSourceHint(.syncFailed) }"
        let before = sync.components(separatedBy: pill).dropLast()
        #expect(before.count == 2, "the precondition: the two failure sites were read, \(before.count)")
        // The line carries the failure's sentence, not just any assignment.
        let withLine = before.filter {
            let site = $0.suffix(160)
            return site.contains("errorMessage = ") && site.contains("ErrorSentence.of(error)")
        }
        #expect(withLine.count == before.count, "a sync failure says only the pill, which goes after its time")
        let player = try code("Sources/Views/PlayerView.swift")
        #expect(player.contains("ControlsNoticeLines(notices: coordinator.notices, error: viewModel.errorMessage)"),
                "the full player shows no line under the controls")
        let lines = try code("Sources/Views/ResumeMessageBanner.swift")
        #expect(lines.contains("NoticePlacement.linesUnderControls(shown: notices.shown, held: notices.held, pillHasRoom: pillHasRoom, error: error)")
                    && lines.contains("ForEach(lines, id: \\.self)"),
                "the lines under the controls leave the lasting failure out")
        let channel = try code("Sources/ViewModels/PlaybackNotices.swift") + (try code("Sources/Models/PlaybackNotice.swift"))
        #expect(!channel.contains("errorMessage"), "the channel's timer reaches the line")
    }

    /// The real open, not the door alone: offline, a title that is not on
    /// the device says so with the network symbol; an open nobody asked for
    /// says nothing.
    @Test("offline sagt das echte Oeffnen eines nicht geladenen Titels es mit dem WLAN-Zeichen, ein Oeffnen ohne Geste schweigt")
    func theRealOpenSaysOfflineWithTheNetwork() async {
        let (notices, folder) = channel(expiry: 60)
        defer { try? FileManager.default.removeItem(at: folder) }
        let coordinator = PlayerCoordinator(provider: MockProvider(), notices: notices)
        let item = LibraryItem(id: "notice-open-\(UUID().uuidString)", media: Self.media, addedAt: nil)
        await Reachability.$assumed.withValue(false) {
            await coordinator.open(item: item, origin: .restore)
        }
        #expect(notices.shown == nil, "an open nobody asked for spoke")
        await Reachability.$assumed.withValue(false) {
            await coordinator.open(item: item, origin: .gesture)
        }
        guard case .openFailed(_, let cause)? = notices.shown else {
            Issue.record("the offline open said nothing in the channel: \(String(describing: notices.shown))")
            return
        }
        #expect(cause == .network, "offline open drew \(cause)")
        #expect(notices.shown?.icon == "wifi.exclamationmark")
        #expect(coordinator.loadError != nil, "the full player's screen lost the sentence")
    }

    private static let media = LibraryItemMedia(metadata: nil, duration: 100, chapters: nil, tracks: nil)

    @Test("die Pille faengt nur ihre eigene Flaeche, ein Tipp oeffnet das Protokoll, die Einstellungen fuehren dorthin", .needsTheSources)
    func thePillTakesOnlyItsOwnCapsule() throws {
        let root = SourceTree.root
        let banner = SyncContractFenceTests.stripped(try String(contentsOf: root.appendingPathComponent("Sources/Views/ResumeMessageBanner.swift"), encoding: .utf8))
        #expect(!banner.contains("allowsHitTesting"), "the pill still lets every touch through")
        let pill = try #require(banner.components(separatedBy: "if let hint = notices.shown {").last?
            .components(separatedBy: ".animation(").first, "the fence did not find the pill")
        #expect(pill.contains(".contentShape(shape)"), "the pill takes more than its capsule")
        #expect(pill.contains(".onTapGesture { showsLog = true }"), "a tap on the pill does not open the log")
        let afterPill = banner.components(separatedBy: ".animation(").last ?? ""
        #expect(afterPill.contains(".sheet(isPresented: $showsLog)"), "the log hangs on the pill and closes with it")
        let settings = SyncContractFenceTests.stripped(try String(contentsOf: root.appendingPathComponent("Sources/Views/SettingsView.swift"), encoding: .utf8))
        #expect(settings.contains("NoticeLogView(notices: coordinator.notices)"), "the settings do not lead to the log")
    }

    /// The two notices of an unreadable download say the decided sentences,
    /// and those stand in the catalog, in German too; a change of the wording
    /// is a decision, not an edit.
    @Test("die zwei Meldungen eines unlesbaren Downloads sagen die entschiedenen Saetze, und die stehen im Katalog", .needsTheSources)
    func theUnreadableDownloadSentencesStandAsDecided() throws {
        let data = try Data(contentsOf: SourceTree.root.appendingPathComponent("Sources/Localizable.xcstrings"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = try #require(json?["strings"] as? [String: Any], "the catalog was not read")
        func german(_ key: String) -> String? {
            let entry = strings[key] as? [String: Any]
            let unit = ((entry?["localizations"] as? [String: Any])?["de"] as? [String: Any])?["stringUnit"] as? [String: Any]
            return unit?["value"] as? String
        }
        let decided: [(PlaybackNotice, String, String)] = [
            (.downloadUnreadable, "Download unreadable, playing from the server",
             "Download nicht lesbar, läuft vom Server"),
            (.downloadUnreadableOffline, "Download unreadable. Online it plays from the server.",
             "Download nicht lesbar. Mit Netz läuft er vom Server."),
        ]
        for (notice, key, sentence) in decided {
            // The notice says the decided key in whatever language the run
            // has: its label is that key's translation from the same catalog.
            let spoken = String(localized: String.LocalizationValue(key))
            #expect(notice.label == spoken, "\(notice.kind) says \(notice.label), the decided key says \(spoken)")
            #expect(strings[key] != nil, "the key of \(notice.kind) left the catalog")
            #expect(german(key) == sentence, "\(notice.kind) says \(String(describing: german(key)))")
        }
    }
}
#endif
