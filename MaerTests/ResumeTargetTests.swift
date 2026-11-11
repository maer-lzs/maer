// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// Continue listening has one decision (`ResumeTarget.pick`) and one door
/// (`PlayerCoordinator.resume`): Siri, the quick action and the widget's
/// link reach it through the library view, the widget's play command from
/// the app's process; neither carries a decision of its own.
@MainActor
struct ResumeTargetTests {
    @Test("die Entscheidung als Tabelle: Siri-Titel vor allem, offener Player vor zuletzt gehoert, Warten nur bei ladender Bibliothek")
    func theDecision() {
        typealias Row = (named: String?, namedKnown: Bool, active: Bool, last: String?, lastKnown: Bool, loading: Bool, want: ResumeTarget)
        let rows: [Row] = [
            ("a", true, true, "b", true, false, .item("a")),
            ("a", false, true, "b", true, true, .waitForLibrary),
            ("a", false, true, "b", true, false, .nothing(missing: .item)),
            (nil, false, true, "b", true, false, .resumeActive),
            (nil, false, true, nil, false, true, .resumeActive),
            (nil, false, false, "b", true, false, .lastPlayed("b")),
            (nil, false, false, "b", false, true, .waitForLibrary),
            (nil, false, false, "b", false, false, .nothing(missing: .lastPlayedNotFound)),
            (nil, false, false, nil, false, false, .nothing(missing: .noLastPlayed)),
            (nil, false, false, nil, false, true, .waitForLibrary),
        ]
        for row in rows {
            let got = ResumeTarget.pick(namedItemId: row.named, namedItemKnown: row.namedKnown, hasActivePlayer: row.active,
                                        lastPlayedId: row.last, lastPlayedKnown: row.lastKnown, libraryLoading: row.loading)
            #expect(got == row.want, "\(row) gave \(got)")
        }
    }

    /// Each way of finding nothing has its own catalog key, so a new
    /// sentence for one case is a catalog value; only a device without a
    /// last played title says there is nothing to continue yet.
    @Test("nichts gefunden sagt je Fall den eigenen Schluessel: ohne Zeiger noch nichts zum Weiterhoeren, Zeiger ohne Titel und unbekannter Titel je einer")
    func eachNothingHasItsSentence() async {
        #expect(ResumeTarget.Missing.noLastPlayed.sentence.key == "Nothing to continue yet.")
        #expect(ResumeTarget.Missing.lastPlayedNotFound.sentence.key == "Nothing to resume: last played not found")
        #expect(ResumeTarget.Missing.item.sentence.key == "Nothing to resume: title not found")
        // Nothing played yet is said with the info symbol, a title gone with the triangle.
        #expect(PlaybackNotice.openFailed("", ResumeTarget.Missing.noLastPlayed.cause).icon == "info.circle")
        #expect(PlaybackNotice.openFailed("", ResumeTarget.Missing.lastPlayedNotFound.cause).icon == "exclamationmark.triangle")
        #expect(PlaybackNotice.openFailed("", ResumeTarget.Missing.item.cause).icon == "exclamationmark.triangle")
        // The log names each case by the word it had as text.
        #expect([ResumeTarget.Missing.item, .noLastPlayed, .lastPlayedNotFound].map(\.rawValue)
                    == ["item", "no last played", "last played not found"])
        // The door keeps its answer, so the view and the command say the
        // case they met.
        let coordinator = PlayerCoordinator(provider: MockProvider())
        let library = LibraryViewModel(provider: MockProvider())
        let target = await coordinator.resume(namedItemId: nil, by: .view, library: library, lastPlayedId: nil)
        #expect(target == .nothing(missing: .noLastPlayed))
        #expect(coordinator.lastResumeTarget == target, "the door forgot the case it met")
    }

    /// What was missing is a case of its own, never text: a new way of
    /// finding nothing must name its sentence and its symbol, and no caller
    /// can ask by a word the rule does not know.
    @Test("was fehlte, ist ein eigener Fall mit Satz und Zeichen, kein Text", .needsTheSources)
    func whatWasMissingIsACase() throws {
        let rule = try FetchAnswerTests.squeezedSource("Sources/Models/ResumeTarget.swift")
        #expect(rule.contains("case nothing(missing: Missing)"), "the nothing case carries text again")
        #expect(!rule.contains("missing: String") && !rule.contains("missing: \""), "what was missing is text again")
        let door = try FetchAnswerTests.squeezedSource("Sources/ViewModels/PlayerCoordinator+Resume.swift")
        for word in [ResumeTarget.Missing.item, .noLastPlayed, .lastPlayedNotFound].map(\.rawValue) {
            #expect(!door.contains("\"\(word)\""), "the door names a case by its word: \(word)")
            #expect(rule.components(separatedBy: "\"\(word)\"").count <= 2, "the rule asks by the word: \(word)")
        }
    }

    /// The three sentences as the catalog holds them, each with its own
    /// wording in English and German.
    @Test("die Saetze fuer nichts gefunden im Katalog: je Fall der eigene Wortlaut englisch und deutsch", .needsTheSources)
    func theNothingSentencesInTheCatalog() throws {
        let catalog = try StringCatalogOrderTests.entries()
        func value(_ key: String, _ language: String) -> String? {
            let localized = (catalog[key]?["localizations"] as? [String: Any])?[language] as? [String: Any]
            return (localized?["stringUnit"] as? [String: Any])?["value"] as? String
        }
        #expect(value("Nothing to continue yet.", "de") == "Noch nichts zum Weiterhören.")
        #expect(value("Nothing to resume: last played not found", "en") == "The last thing you played is no longer available.")
        #expect(value("Nothing to resume: last played not found", "de") == "Das zuletzt Gehörte ist nicht mehr verfügbar.")
        #expect(value("Nothing to resume: title not found", "en") == "This title is no longer available.")
        #expect(value("Nothing to resume: title not found", "de") == "Dieser Titel ist nicht mehr verfügbar.")
    }

    @Test("Ansicht und Befehl treffen an der Tuer dieselbe Entscheidung: ein Titel der Bibliothek ist zuletzt gehoert, ein unbekannter ist nichts")
    func theViewAndTheCommandDecideAlike() async throws {
        let known = "resume-known-\(UUID().uuidString)"
        let library = LibraryViewModel(provider: MockProvider())
        library.entries = [LibraryEntry(item: LibraryItem(id: known, media: nil, addedAt: nil), progress: nil)]
        let unknown = "resume-unknown-\(UUID().uuidString)"
        for (lastPlayed, want) in [(unknown, ResumeTarget.nothing(missing: .lastPlayedNotFound)), (known, .lastPlayed(known))] {
            var targets: [ResumeTarget] = []
            for caller in [PlayerCoordinator.ResumeCaller.view, .command] {
                let coordinator = PlayerCoordinator(provider: MockProvider())
                // The open after the decision asks a server this host has
                // not; it fails without touching the queue or the context.
                await Reachability.$assumed.withValue(true) {
                    targets.append(await coordinator.resume(namedItemId: nil, by: caller, library: library, lastPlayedId: lastPlayed))
                }
            }
            #expect(targets == [want, want], "the view and the command decided apart: \(targets)")
        }
    }

    @Test("zuletzt gehoert, nicht im Speicher der Sitzung, aber aufloesbar: jede Art wird von Ansicht und Befehl gefunden")
    func everyKindResolvesBeyondTheSessionsMemory() async {
        let library = LibraryViewModel(provider: MockProvider())
        let suffix = UUID().uuidString
        // Each id in the form its source builds: the seam replaces the
        // restore's chain, so the forms prove the door passes every one on.
        let ids = [SubsonicProvider.itemId(songId: suffix), JellyfinProvider.itemId(songId: suffix),
                   "abspod:show\(suffix):episode\(suffix)", "rss:feed\(suffix):\(suffix)",
                   "radio:\(suffix)", "lva:\(suffix)", "book-\(suffix)"]
        for id in ids {
            #expect(AppSession.shared.libraryItem(forId: id) == nil, "the precondition: \(id) is in the session's memory")
            var asked: [String] = []
            var targets: [ResumeTarget] = []
            for caller in [PlayerCoordinator.ResumeCaller.view, .command] {
                let coordinator = PlayerCoordinator(provider: MockProvider())
                await Reachability.$assumed.withValue(true) {
                    targets.append(await coordinator.resume(namedItemId: nil, by: caller, library: library, lastPlayedId: id,
                                                            resolve: { lastId, _, allowsShowNewest in
                                                                asked.append("\(lastId) \(allowsShowNewest)")
                                                                return LibraryItem(id: lastId, media: nil, addedAt: nil)
                                                            }))
                }
            }
            #expect(targets == [.lastPlayed(id), .lastPlayed(id)], "\(id) was not found: \(targets)")
            #expect(asked == ["\(id) false", "\(id) false"], "the door asked for \(id) with the neighbour, and plays what it finds")
        }
    }

    @Test("zuletzt gehoert, eine Folge, die aus Feed und Historie fiel: die Tuer spielt nicht die neueste der Sendung, sie findet nichts")
    func theLastPlayedEpisodeNeverPlaysItsNeighbour() async {
        let library = LibraryViewModel(provider: MockProvider())
        let suffix = UUID().uuidString
        let gone = "rss:feed:\(suffix)#gone"
        let newest = LibraryItem(id: "rss:feed:\(suffix)#newest", media: nil, addedAt: nil)
        var targets: [ResumeTarget] = []
        for caller in [PlayerCoordinator.ResumeCaller.view, .command] {
            let coordinator = PlayerCoordinator(provider: MockProvider())
            await Reachability.$assumed.withValue(true) {
                targets.append(await coordinator.resume(namedItemId: nil, by: caller, library: library, lastPlayedId: gone,
                                                        resolve: { _, _, allowsShowNewest in
                                                            PlayerCoordinator.standbyTail(fetched: nil, showNewest: newest,
                                                                                          allowsShowNewest: allowsShowNewest).0
                                                        }))
            }
            #expect(coordinator.viewModel == nil, "the door opened a player for the show's newest episode")
        }
        #expect(targets == [.nothing(missing: .lastPlayedNotFound), .nothing(missing: .lastPlayedNotFound)],
                "the door continued another title than the last played: \(targets)")
        #expect(targets.allSatisfy { $0.findsNothing }, "nothing found must bring the sentence")
    }

    @Test("ein genannter Titel (Siri, Zeile eines Widgets), nicht im Speicher der Sitzung, wird ueber die Kette gefunden, nie der Nachbar")
    func aNamedTitleResolvesWithoutItsNeighbour() async {
        let library = LibraryViewModel(provider: MockProvider())
        let suffix = UUID().uuidString
        for id in ["sub:song:\(suffix)", "jf:item:\(suffix)", "rss:feed:\(suffix)#ep", "radio:\(suffix)", "book-\(suffix)"] {
            #expect(AppSession.shared.libraryItem(forId: id) == nil, "the precondition: \(id) is in the session's memory")
            var asked: [String] = []
            var targets: [ResumeTarget] = []
            for caller in [PlayerCoordinator.ResumeCaller.view, .command] {
                let coordinator = PlayerCoordinator(provider: MockProvider())
                await Reachability.$assumed.withValue(true) {
                    targets.append(await coordinator.resume(namedItemId: id, by: caller, library: library,
                                                            lastPlayedId: "resume-last-\(suffix)",
                                                            resolve: { namedId, _, allowsShowNewest in
                                                                asked.append("\(namedId) \(allowsShowNewest)")
                                                                return LibraryItem(id: namedId, media: nil, addedAt: nil)
                                                            }))
                }
            }
            #expect(targets == [.item(id), .item(id)], "\(id) was not found: \(targets)")
            #expect(asked == ["\(id) false", "\(id) false"], "the door asked for \(id) another way than the play on a foreign claim")
        }
    }

    @Test("ein Befehl ohne Titel hinterlaesst keinen Wunsch: kein Auftrag fuer die Ansicht, kein Player")
    func aCommandLeavesNoRequest() async {
        let before = (ResumeRequest.pending, ResumeRequest.pendingItemId)
        defer { (ResumeRequest.pending, ResumeRequest.pendingItemId) = before }
        ResumeRequest.pending = false
        ResumeRequest.pendingItemId = nil
        let library = LibraryViewModel(provider: MockProvider())
        library.entries = [LibraryEntry(item: LibraryItem(id: "known", media: nil, addedAt: nil), progress: nil)]
        let coordinator = PlayerCoordinator(provider: MockProvider())
        let target = await coordinator.resume(namedItemId: nil, by: .command, library: library,
                                              lastPlayedId: "resume-none-\(UUID().uuidString)")
        #expect(target == .nothing(missing: .lastPlayedNotFound))
        #expect(!ResumeRequest.pending && ResumeRequest.pendingItemId == nil, "the command left a request the view would play later")
        #expect(coordinator.viewModel == nil)
    }

    @Test("der Befehl ohne Werk der App tut nichts, mit ihm genau einmal das Werk")
    func theCommandRunsTheAppsWork() async throws {
        let before = ResumeListeningIntent.handler
        defer { ResumeListeningIntent.handler = before }
        ResumeListeningIntent.handler = nil
        _ = try await ResumeListeningIntent().perform()
        var runs: [String?] = []
        ResumeListeningIntent.handler = { runs.append($0); return true }
        _ = try await ResumeListeningIntent().perform()
        _ = try await ResumeListeningIntent(itemId: "row-title").perform()
        #expect(runs == [nil, "row-title"], "the work did not run once per command, with the title a row names")
    }

    @Test("findet der Befehl nichts, holt er die App nach vorn und sie sagt es; findet er etwas, bleibt sie im Hintergrund")
    func aCommandThatFindsNothingSaysSo() async throws {
        let before = (ResumeListeningIntent.handler, ResumeListeningIntent.saysNothing, ResumeListeningIntent.opensApp)
        defer { (ResumeListeningIntent.handler, ResumeListeningIntent.saysNothing, ResumeListeningIntent.opensApp) = before }
        var steps: [String] = []
        ResumeListeningIntent.saysNothing = { steps.append("says") }
        ResumeListeningIntent.opensApp = { _ in steps.append("front"); return true }
        ResumeListeningIntent.handler = { _ in true }
        _ = try await ResumeListeningIntent().perform()
        #expect(steps.isEmpty, "a command that continues brought the app to the front: \(steps)")
        ResumeListeningIntent.handler = { _ in false }
        _ = try await ResumeListeningIntent().perform()
        #expect(steps == ["front", "says"], "nothing found: the app comes to the front, then says so")
        steps = []
        ResumeListeningIntent.opensApp = { _ in steps.append("front"); return false }
        _ = try await ResumeListeningIntent().perform()
        #expect(steps == ["front"], "where the system cannot bring the app to the front, nothing is said into the dark")
        #expect(ResumeTarget.nothing(missing: .item).findsNothing && !ResumeTarget.waitForLibrary.findsNothing
                    && !ResumeTarget.lastPlayed("a").findsNothing && !ResumeTarget.resumeActive.findsNothing)
    }

    @Test("der Link des Widgets: ohne Titel weiterhoeren, mit Titel genau diesen, jede Kennung kommt unversehrt an")
    func theWidgetsLink() throws {
        let plain = ResumeLink.url(itemId: nil)
        #expect(plain.absoluteString == "maer://resume")
        #expect(ResumeLink.asksToResume(plain) && ResumeLink.itemId(in: plain) == nil)
        for id in ["li_book-1", "rss:https://feed.example/a?b=c&d#ep 1/ä", "sub:song:1", "lva:x+y=z"] {
            #expect(ResumeLink.itemId(in: ResumeLink.url(itemId: id)) == id, "\(id) did not come back")
        }
        #expect(ResumeLink.itemId(in: try #require(URL(string: "maer://resume/"))) == nil, "an empty title is a title")
        let other = try #require(URL(string: "https://maer.fm/resume/a"))
        #expect(!ResumeLink.asksToResume(other) && ResumeLink.itemId(in: other) == nil)
    }

    @Test("ein Link maer: wird streng gelesen: nur die Form des Widgets und eine bekannte Kennung, sonst fragt er nichts")
    func theLinkIsReadStrictly() throws {
        typealias Check = ResumeLinkCheck
        #expect(Check.ask(in: ResumeLink.url(itemId: nil)) == .resume)
        #expect(Check.ask(in: try #require(URL(string: "maer://resume/"))) == .resume)
        for id in ["li_book-1", "rss:https://feed.example/a?b=c&d#ep 1/ä", "sub:song:1", "jf:book:7"] {
            #expect(Check.ask(in: ResumeLink.url(itemId: id)) == .title(id), "\(id) was refused")
        }
        for raw in ["maer://play/li_1", "maer://resume/li_1?autoplay=1", "maer://resume/li_1#x", "maer://user:pw@resume/li_1",
                    "maer://resume:99/li_1", "maer:resume", "maer://resume/evil:payload", "MAER://resume/li_1"] {
            #expect(Check.ask(in: try #require(URL(string: raw))) == nil, "\(raw) was taken")
        }
        #expect(Check.ask(in: ResumeLink.url(itemId: "rss:a\u{0007}b")) == nil, "a control character was taken")
        #expect(Check.ask(in: ResumeLink.url(itemId: "li_" + String(repeating: "x", count: Check.longestId))) == nil,
                "an endless title was taken")
    }

    /// The text between a function's head and the next `func` of the file.
    private func body(of head: String, in file: String) throws -> String {
        let text = try FetchAnswerTests.squeezedSource(file)
        let start = try #require(text.range(of: head), "\(head) is gone from \(file)")
        let rest = text[start.upperBound...]
        let end = rest.range(of: " func ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    @Test("der Befehl des Widgets steht nicht neben Siris gleichnamiger Aktion in Kurzbefehlen und Suche", .needsTheSources)
    func theWidgetsCommandIsNotListed() throws {
        let shared = try FetchAnswerTests.squeezedSource("Sources/Models/WidgetShared.swift")
        let intent = try #require(shared.range(of: "struct ResumeListeningIntent: AudioPlaybackIntent {"), "the command is gone")
        let head = String(shared[intent.upperBound...].prefix(400))
        #expect(head.contains("static let isDiscoverable = false"),
                "the widget's command is listed beside Siri's action of the same name")
    }

    @Test("Ansicht, Siri und Befehl tragen keine eigene Entscheidung, alle fragen die Tuer; das Werk setzt die App beim Start", .needsTheSources)
    func noCallerDecidesOnItsOwn() throws {
        let view = try body(of: "private func handlePendingResumeRequest() async", in: "Sources/Views/LibraryView.swift")
        #expect(view.contains("playerCoordinator.resume(namedItemId: named, by: .view, library: viewModel)"), "the view does not ask the door")
        let siri = try body(of: "func perform() async throws -> some IntentResult", in: "Sources/AppShortcuts.swift")
        let command = try body(of: "func perform() async throws -> some IntentResult", in: "Sources/Models/WidgetShared.swift")
        for (name, text) in [("view", view), ("siri", siri), ("command", command)] {
            for decision in ["lastPlayedItemIdValue", "playWithServerCheck", "open(item:"] {
                #expect(!text.contains(decision), "\(name) decides on its own: \(decision)")
            }
        }
        #expect(!command.contains("ResumeRequest"), "the command leaves a request for the view")
        let door = try body(of: "func resume(namedItemId: String?, by caller: ResumeCaller,",
                            in: "Sources/ViewModels/PlayerCoordinator+Resume.swift")
        #expect(door.contains("await self.resolveStandbyItem(id, entries: entries, allowsShowNewest: allowsShowNewest)"),
                "the door resolves titles another way than the app's own restore")
        #expect(door.contains("named = await resolve(namedItemId, entries, false)"),
                "a named title may become the show's newest episode beside it")
        #expect(door.contains("last = await resolve(lastPlayedId, entries, false)"),
                "the last played title may become the show's newest episode beside it, and plays")
        let app = try FetchAnswerTests.squeezedSource("Sources/MaerApp.swift")
        #expect(app.contains("ResumeListeningIntent.handler = { itemId in let target = await AppSession.shared.playerCoordinator.resume(namedItemId: itemId, by: .command) return !target.findsNothing }"),
                "the app does not give the command its work at start, with the title a row names")
        #expect(app.contains("ResumeListeningIntent.saysNothing = { AppSession.shared.playerCoordinator.sayNothingToResume() }"),
                "the command says nothing found another way than the view")
        #expect(view.contains("if target.findsNothing { playerCoordinator.sayNothingToResume() }"),
                "the view says nothing found another way than the command")
        let sentence = try FetchAnswerTests.squeezedSource("Sources/ViewModels/PlayerCoordinator+Resume.swift")
        #expect(sentence.contains("sayOpenFailure(String(localized: missing.sentence), cause: missing.cause, title: nil)"),
                "the sentence or its symbol for nothing found is not the one rule's")
        #expect(!sentence.contains("Audiobook could not be loaded."), "the door says a sentence of its own")
        #expect(door.contains("lastResumeTarget = target"), "the door does not keep the case it met")
        let shortcuts = try FetchAnswerTests.squeezedSource("Sources/AppShortcuts.swift")
        #expect(shortcuts.contains("ResumeRequest.pendingItemId = book.itemId"), "Siri's named book does not reach the door through the view")
        let link = try FetchAnswerTests.squeezedSource("Sources/Views/LibraryView.swift")
        #expect(link.contains("guard let ask = ResumeLinkCheck.ask(in: url) else {"), "a link reaches the door unchecked")
        #expect(link.contains("if case .title(let id) = ask { ResumeRequest.pendingItemId = id } else { ResumeRequest.pendingItemId = nil }"),
                "the widget's link does not hand its title to the door")
        #expect(!link.contains("ResumeRequest.pendingItemId = ResumeLink.itemId(in: url)"))
    }

    /// The door waits while the title resolves; another title opened
    /// meanwhile wins over it (`WaitWindow`), and the door opens nothing.
    @Test("die Tuer zum Weiterhoeren oeffnet nichts, wenn waehrend des Aufloesens ein anderer Titel geoeffnet wurde")
    func theDoorYieldsToATitleOpenedMeanwhile() async {
        let coordinator = PlayerCoordinator(provider: MockProvider())
        let library = LibraryViewModel(provider: MockProvider())
        let other = LibraryItem(id: "opened-meanwhile-\(UUID().uuidString)", media: nil, addedAt: nil)
        let named = LibraryItem(id: "named-\(UUID().uuidString)", media: nil, addedAt: nil)
        _ = await coordinator.resume(namedItemId: named.id, by: .command, library: library, lastPlayedId: nil) { _, _, _ in
            coordinator._seedActivePlayerForUITest(
                item: other,
                detail: LibraryItemDetail(id: other.id, media: LibraryItemMedia(metadata: nil, duration: 60, chapters: nil, tracks: nil),
                                          userMediaProgress: nil),
                chapters: [], currentChapterIndex: 0, isFallback: false)
            return named
        }
        #expect(coordinator.activeItem?.id == other.id, "the door opened its title over the one opened meanwhile")
    }

    /// The standby mirror and the open on a foreign claim ask the same
    /// window after their title resolved; the mirror also yields to a play.
    @Test("Spiegel der Bereitschaft und fremder Anspruch fragen nach dem Aufloesen das Fenster", .needsTheSources)
    func theMirrorAndTheClaimAskTheWindow() throws {
        let coordinator = try FetchAnswerTests.squeezedSource("Sources/ViewModels/PlayerCoordinator.swift")
        #expect(coordinator.contains("let before = waitWindow if let item = await resolveStandbyItem(itemId, allowsShowNewest: false) { guard WaitWindow.stillStands(before, waitWindow) else {"),
                "the open on a foreign claim does not ask after the wait")
        #expect(coordinator.contains("let before = waitWindow if let item = await resolveStandbyItem(target, allowsShowNewest: false) { guard WaitWindow.stillStands(before, waitWindow), viewModel?.isPlaying != true else {"),
                "the mirror swaps without asking after the wait")
    }
}
#endif
