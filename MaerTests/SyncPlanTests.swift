// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The behaviour witness of the player's position writes: which occasion,
/// in which state, leads to which write. Built on the pure plan, without a
/// player.
struct SyncPlanTests {
    static let deliberate = SyncOrigin.allCases.filter(\.isDeliberate)

    static func state(resolved: Bool = true, at currentTime: Double = 110, last: Double = 100,
                      suppress: Bool = false, pending: Bool = false, progressSync: Bool = true,
                      podcast: Bool = false, pot: Bool = false) -> SyncState {
        SyncState(startSourceResolved: resolved, currentTime: currentTime, lastSyncedTime: last,
                  suspiciousDropThreshold: 120, suppressConflict: suppress, conflictPending: pending,
                  progressSync: progressSync, podcastEpisode: podcast, potCarries: pot)
    }

    /// Every state the rule tells apart: the start answered or not; six
    /// distances (equal, five ahead, a small step back, a big drop, and an
    /// unknown number on either side, where a comparison turned around
    /// answers differently); the conflict suppressed and pending; the kind
    /// of source; podcast; pot.
    static var allStates: [SyncState] {
        var out: [SyncState] = []
        let positions: [(Double, Double)] = [(100, 100), (105, 100), (97, 100), (0, 500),
                                             (.nan, 100), (100, .nan)]
        for resolved in [true, false] {
            for (now, last) in positions {
                for suppress in [true, false] {
                    for pending in [true, false] {
                        for progressSync in [true, false] {
                            for podcast in [true, false] {
                                for pot in [true, false] {
                                    out.append(state(resolved: resolved, at: now, last: last, suppress: suppress,
                                                     pending: pending, progressSync: progressSync,
                                                     podcast: podcast, pot: pot))
                                }
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    /// The branches of `performSync(force:)` as they stood before the plan,
    /// transcribed in their own order: guard, guard, drop
    /// check, then the effects after a landed write.
    static func former(force: Bool, _ s: SyncState) -> SyncPlan {
        var gate = SyncPlan.Gate.write
        if !s.startSourceResolved {
            gate = .unresolvedStart
        } else if !(force || abs(s.currentTime - s.lastSyncedTime) >= 5) {
            gate = .belowThreshold
        } else if !s.suppressConflict && s.currentTime < s.lastSyncedTime - s.suspiciousDropThreshold {
            gate = .conflict(raise: !s.conflictPending)
        }
        return SyncPlan(gate: gate, logWrite: force, noteServerWrite: s.progressSync,
                        noteLibrary: !s.potCarries, flushesBackup: s.progressSync && !s.podcastEpisode,
                        gpodder: s.podcastEpisode, potDeliberate: force)
    }

    static func formerLocal(_ s: SyncState, eventSinceLoad: Bool) -> SyncPlan.Local {
        if s.progressSync && !s.podcastEpisode { return .flushBackup }
        return eventSinceLoad ? .recordEpisode : .nothing
    }

    @Test("jeder bewusste Anlass hat in jedem Zustand denselben Plan, der Tick den frueheren ohne force")
    func theOccasionDecidesOnlyWhatForceDecided() {
        let states = Self.allStates
        #expect(states.count == 384)
        for s in states {
            let plans = Self.deliberate.map { SyncRules.plan(origin: $0, state: s) }
            #expect(Set(plans.map { "\($0)" }).count == 1, "bewusste Anlaesse unterscheiden sich in \(s)")
            #expect(plans.first == Self.former(force: true, s), "bewusst weicht vom frueheren force ab in \(s)")
            #expect(SyncRules.plan(origin: .tick, state: s) == Self.former(force: false, s),
                    "der Tick weicht vom frueheren Plan ohne force ab in \(s)")
            for event in [true, false] {
                #expect(SyncRules.plan(origin: .pause, state: s).local(eventSinceLoad: event)
                        == Self.formerLocal(s, eventSinceLoad: event), "lokaler Schrieb weicht ab in \(s)")
            }
        }
    }

    // Each branch of the plan, named once, so a probe on one branch tears
    // one line here.

    @Test("ein Start ohne Antwort schreibt nicht, auch nicht bewusst")
    func anUnansweredStartDoesNotWrite() {
        #expect(SyncRules.plan(origin: .pause, state: Self.state(resolved: false)).gate == .unresolvedStart)
    }

    @Test("der Tick wartet fuenf Sekunden, ein bewusster Anlass nicht")
    func theTickWaitsFiveSeconds() {
        let near = Self.state(at: 103, last: 100)
        #expect(SyncRules.plan(origin: .tick, state: near).gate == .belowThreshold)
        #expect(SyncRules.plan(origin: .seek, state: near).gate == .write)
        #expect(SyncRules.plan(origin: .tick, state: Self.state(at: 105, last: 100)).gate == .write)
        #expect(SyncRules.plan(origin: .tick, state: Self.state(at: .nan, last: 100)).gate == .belowThreshold,
                "ein Tick ohne bekannte Position schreibt nicht, wie vorher")
        #expect(SyncRules.plan(origin: .tick, state: Self.state(at: 100, last: .nan)).gate == .belowThreshold)
    }

    @Test("ein grosser Ruecksprung wird nie still geschrieben, ausser er ist bestaetigt")
    func aBigDropIsNeverWrittenSilently() {
        #expect(SyncRules.plan(origin: .pause, state: Self.state(at: 0, last: 500)).gate == .conflict(raise: true))
        #expect(SyncRules.plan(origin: .pause, state: Self.state(at: 0, last: 500, pending: true)).gate
                == .conflict(raise: false), "ein gezeigter Konflikt wird nicht noch einmal gezeigt")
        #expect(SyncRules.plan(origin: .confirmLower, state: Self.state(at: 0, last: 500, suppress: true)).gate
                == .write, "ein bestaetigter Ruecksprung wird geschrieben")
    }

    @Test("ein Buch raeumt den Absturz-Rueckhalt, eine Folge schreibt nur nach einem Ereignis")
    func booksFlushEpisodesRecordOnlyAfterAnEvent() {
        let book = SyncRules.plan(origin: .pause, state: Self.state())
        #expect(book.local(eventSinceLoad: false) == .flushBackup)
        let episode = SyncRules.plan(origin: .restoreFlush, state: Self.state(podcast: true))
        #expect(episode.local(eventSinceLoad: false) == .nothing, "nur geladen ist nicht gehoert")
        #expect(episode.local(eventSinceLoad: true) == .recordEpisode)
        #expect(episode.gpodder, "eine Folge meldet gpodder")
        #expect(!book.gpodder)
        let scrobbler = SyncRules.plan(origin: .pause, state: Self.state(progressSync: false))
        #expect(scrobbler.local(eventSinceLoad: true) == .recordEpisode && !scrobbler.noteServerWrite)
    }

    @Test("der Topf und das Log hoeren bewusste Anlaesse sofort, den Tick nicht")
    func theTickIsQuiet() {
        let tick = SyncRules.plan(origin: .tick, state: Self.state())
        let pause = SyncRules.plan(origin: .pause, state: Self.state())
        #expect(!tick.potDeliberate && !tick.logWrite)
        #expect(pause.potDeliberate && pause.logWrite)
    }

    @Test("was der Topf traegt, lernt das Bibliotheksmodell nicht")
    func whatThePotCarriesSkipsTheLibrary() {
        #expect(!SyncRules.plan(origin: .pause, state: Self.state(pot: true)).noteLibrary)
        #expect(SyncRules.plan(origin: .pause, state: Self.state(pot: false)).noteLibrary)
    }

    /// `performSync` carries the plan out and decides nothing of its own:
    /// each branch reads the plan, or the outcome of the write (the item
    /// exists, the refresh read answered, the status changed, the error was
    /// an offline one). Named here, one line each.
    nonisolated static let outcomeBranches = [
        "guard let item else { return }",
        "if raise {",
        "if let fresh = try? await provider.fetchItemDetail(itemId: item.id),",
        "if syncStatus != .synced {",
        "if NetworkStatus.isOfflineError(error) {",
        "if syncStatus != .queued { showSourceHint(.queued) }",
    ]

    nonisolated static func ownDecisions(in body: String) -> [String] {
        body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                ["if ", "guard ", "switch ", "} else if ", "else if ", "while "].contains { line.hasPrefix($0) }
                    || line.contains(" ? ")
            }
            .filter { !$0.contains("plan.") && !outcomeBranches.contains($0) }
    }

    @Test("die Ausfuehrung entscheidet nichts selbst", .needsTheSources)
    func theExecutionDecidesNothing() throws {
        let text = try String(contentsOf: SourceTree.root.appendingPathComponent(
            "Sources/ViewModels/PlayerViewModel+Sync.swift"), encoding: .utf8)
        let body = try #require(functionBody(of: "private func performSync(_ origin: SyncOrigin) async {", in: text))
        #expect(body.contains("SyncRules.plan(origin: origin"), "die Ausfuehrung fragt den Plan nicht mehr")
        #expect(Self.ownDecisions(in: body).isEmpty, "eigene Entscheidungen: \(Self.ownDecisions(in: body))")
        #expect(Self.ownDecisions(in: "        if provider.capabilities.contains(.progressSync) {").count == 1,
                "der Zaun sieht eine Entscheidung nach Art der Quelle")
        #expect(Self.ownDecisions(in: "        guard force || abs(currentTime - lastSyncedTime) >= 5 else { return }").count == 1)
    }
}
#endif
