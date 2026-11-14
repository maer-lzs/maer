// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The measuring instrument for a heard mark flipping back: it must
/// SEPARATE the two causes, not suggest one of them.
struct ProgressDiagnosisTests {
    private func entry(position: Double, updatedAt: Double, duration: Double) -> ProgressDiagnosis.Entry {
        .init(title: "Folge 26", guid: "rss:x:26", position: position,
              updatedAt: updatedAt, feedDuration: duration)
    }

    @Test("a grown duration drops the mark, exactly the picture from the finding")
    func grownDurationShowsAsInProgress() {
        // Marked as heard at 3.420 s; the feed reports three minutes more today.
        let e = entry(position: 3_420, updatedAt: 1_000, duration: 3_600)
        #expect(ProgressDiagnosis.verdict(e, tail: 0) == .inProgress(remaining: 180))
        // And with the duration of back then it would have been heard.
        #expect(ProgressDiagnosis.verdict(entry(position: 3_420, updatedAt: 1_000, duration: 3_420), tail: 0) == .played)
    }

    @Test("the timestamp separates the two theses, that is the whole purpose")
    func timestampSeparatesTheCauses() {
        let sync: Double = 10_000
        // Written long before the sync: nobody touched it.
        #expect(ProgressDiagnosis.trace(entry(position: 1, updatedAt: 5_000, duration: 60),
                                        lastSync: sync) == .olderThanSync)
        // Written at the sync: something overwrote it.
        #expect(ProgressDiagnosis.trace(entry(position: 1, updatedAt: 10_030, duration: 60),
                                        lastSync: sync) == .writtenBySync)
        // Written afterwards: the own hand.
        #expect(ProgressDiagnosis.trace(entry(position: 1, updatedAt: 20_000, duration: 60),
                                        lastSync: sync) == .newerThanSync)
        // Without a known sync NOTHING is claimed.
        #expect(ProgressDiagnosis.trace(entry(position: 1, updatedAt: 20_000, duration: 60),
                                        lastSync: nil) == .noSyncKnown)
    }

    @Test("the report names position, today's duration, timestamp and its interpretation")
    func reportCarriesTheDecidingValues() {
        let text = ProgressDiagnosis.report(
            show: "The Rest Is History",
            entries: [entry(position: 3_420, updatedAt: 5_000, duration: 3_600)],
            lastSync: 10_000, now: 20_000,
            format: { String(Int($0)) })
        #expect(text.contains("3420"))
        #expect(text.contains("3600"))
        #expect(text.contains("Dauer-These"), "die Deutung des Zeitstempels muss dastehen")
        #expect(text.contains("rss:x:26"))
    }

    @Test("without stored positions the report says so, instead of being empty")
    func emptyIsStated() {
        let text = ProgressDiagnosis.report(show: "Leer", entries: [], lastSync: nil,
                                            now: 0, format: { String(Int($0)) })
        #expect(text.contains("Keine gespeicherten Positionen"))
    }
}


// MARK: - The BOOK view of the same instrument

struct BookProgressDiagnosisTests {
    private func stamp(_ s: Double) -> String { String(Int(s)) }
    private func time(_ s: Double) -> String { String(Int(s)) + "s" }

    @Test("the report names the jump back that the start would trigger")
    func namesTheBackwardJump() {
        // The measured situation: locally clearly further, but stamped OLDER
        // than the server state ⇒ the start takes the server and
        // throws back. Exactly that is what the instrument must say.
        let sources = ProgressDiagnosis.BookSources(
            serverPosition: 3600, serverUpdatedAtMs: 2_000_000,
            localPosition: 4800, localSavedAtMs: 1_000_000,
            cachedPosition: 3600, cachedUpdatedAtMs: 2_000_000,
            duration: 36000, isDownloaded: true, pendingSyncOperations: 0)
        let report = ProgressDiagnosis.bookReport(title: "Winterfell", sources: sources,
                                                  now: 3_000, format: stamp, formatTime: time)
        #expect(report.contains("SERVER-Stand"))
        #expect(report.contains("1200 s zurück"))
        #expect(report.contains("heruntergeladen: ja"))
    }

    @Test("a NEWER local state wins, and the report says so")
    func localWinsWhenNewer() {
        let sources = ProgressDiagnosis.BookSources(
            serverPosition: 3600, serverUpdatedAtMs: 1_000_000,
            localPosition: 4800, localSavedAtMs: 2_000_000,
            cachedPosition: 3600, cachedUpdatedAtMs: 1_000_000,
            duration: 36000, isDownloaded: true, pendingSyncOperations: 2)
        let report = ProgressDiagnosis.bookReport(title: "Winterfell", sources: sources,
                                                  now: 3_000, format: stamp, formatTime: time)
        #expect(report.contains("LOKALEN Stand"))
        #expect(report.contains("offene Sync-Aufträge: 2"))
    }

    @Test("missing pages are named, not invented")
    func missingSidesAreNamed() {
        let sources = ProgressDiagnosis.BookSources(
            serverPosition: nil, serverUpdatedAtMs: nil,
            localPosition: 900, localSavedAtMs: 5_000,
            cachedPosition: nil, cachedUpdatedAtMs: nil,
            duration: 0, isDownloaded: false, pendingSyncOperations: 0)
        let report = ProgressDiagnosis.bookReport(title: "X", sources: sources,
                                                  now: 3_000, format: stamp, formatTime: time)
        #expect(report.contains("Server-Stand: —"))
        #expect(report.contains("Dauer: unbekannt"))
        #expect(report.contains("Nicht beide Seiten bekannt"))
    }
}
#endif
