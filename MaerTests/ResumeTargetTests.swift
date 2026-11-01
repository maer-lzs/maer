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
            ("a", false, true, "b", true, false, .nothing(missing: "item")),
            (nil, false, true, "b", true, false, .resumeActive),
            (nil, false, true, nil, false, true, .resumeActive),
            (nil, false, false, "b", true, false, .lastPlayed("b")),
            (nil, false, false, "b", false, true, .waitForLibrary),
            (nil, false, false, "b", false, false, .nothing(missing: "last played not found")),
            (nil, false, false, nil, false, false, .nothing(missing: "no last played")),
            (nil, false, false, nil, false, true, .waitForLibrary),
        ]
        for row in rows {
            let got = ResumeTarget.pick(namedItemId: row.named, namedItemKnown: row.namedKnown, hasActivePlayer: row.active,
                                        lastPlayedId: row.last, lastPlayedKnown: row.lastKnown, libraryLoading: row.loading)
            #expect(got == row.want, "\(row) gave \(got)")
        }
    }

    @Test("Ansicht und Befehl treffen an der Tuer dieselbe Entscheidung: ein Titel der Bibliothek ist zuletzt gehoert, ein unbekannter ist nichts")
    func theViewAndTheCommandDecideAlike() async throws {
        let known = "resume-known-\(UUID().uuidString)"
        let library = LibraryViewModel(provider: MockProvider())
        library.entries = [LibraryEntry(item: LibraryItem(id: known, media: nil, addedAt: nil), progress: nil)]
        let unknown = "resume-unknown-\(UUID().uuidString)"
        for (lastPlayed, want) in [(unknown, ResumeTarget.nothing(missing: "last played not found")), (known, .lastPlayed(known))] {
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
                                                            resolveLast: { lastId, _ in
                                                                asked.append(lastId)
                                                                return LibraryItem(id: lastId, media: nil, addedAt: nil)
                                                            }))
                }
            }
            #expect(targets == [.lastPlayed(id), .lastPlayed(id)], "\(id) was not found: \(targets)")
            #expect(asked == [id, id], "the door did not ask the restore's chain for \(id)")
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
        #expect(target == .nothing(missing: "last played not found"))
        #expect(!ResumeRequest.pending && ResumeRequest.pendingItemId == nil, "the command left a request the view would play later")
        #expect(coordinator.viewModel == nil)
    }

    @Test("der Befehl ohne Werk der App tut nichts, mit ihm genau einmal das Werk")
    func theCommandRunsTheAppsWork() async throws {
        let before = ResumeListeningIntent.handler
        defer { ResumeListeningIntent.handler = before }
        ResumeListeningIntent.handler = nil
        _ = try await ResumeListeningIntent().perform()
        var runs = 0
        ResumeListeningIntent.handler = { runs += 1 }
        _ = try await ResumeListeningIntent().perform()
        #expect(runs == 1)
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
        #expect(door.contains("last = await resolveStandbyItem(lastPlayedId, entries: entries, allowsShowNewest: true)"),
                "the door resolves the last played title another way than the app's own restore")
        let app = try FetchAnswerTests.squeezedSource("Sources/MaerApp.swift")
        #expect(app.contains("ResumeListeningIntent.handler = { await AppSession.shared.playerCoordinator.resume(namedItemId: nil, by: .command) }"),
                "the app does not give the command its work at start")
    }
}
#endif
