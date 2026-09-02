// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The host distance as a rule: what earns it, how long it holds, and
/// that it is ONE memory for every path that speaks to the host.
struct CatalogHostGuardTests {
    @Test("nur eine Verweigerung verdient dem Host seinen Abstand")
    func onlyRefusalCounts() {
        #expect(CatalogHostGuard.isRefusal(URLError(.cannotConnectToHost)))
        #expect(CatalogHostGuard.isRefusal(URLError(.networkConnectionLost)))
        // Rot-Proben: Zeitueberschreitung, Abbruch, Dekodierfehler sagen
        // nichts ueber einen ueberrannten Host.
        #expect(!CatalogHostGuard.isRefusal(URLError(.timedOut)))
        #expect(!CatalogHostGuard.isRefusal(URLError(.cancelled)))
        #expect(!CatalogHostGuard.isRefusal(CancellationError()))
        #expect(!CatalogHostGuard.isRefusal(NSError(domain: "x", code: 1)))
    }

    @Test("der Abstand haelt blockSeconds und faellt danach")
    func distanceWindow() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let since = ["archive.org": t0]
        #expect(CatalogHostGuard.isBlocked("archive.org", since: since, now: t0.addingTimeInterval(1)))
        #expect(CatalogHostGuard.isBlocked("archive.org", since: since,
                                           now: t0.addingTimeInterval(CatalogHostGuard.blockSeconds - 1)))
        #expect(!CatalogHostGuard.isBlocked("archive.org", since: since,
                                            now: t0.addingTimeInterval(CatalogHostGuard.blockSeconds)))
        #expect(!CatalogHostGuard.isBlocked("gutendex.com", since: since, now: t0.addingTimeInterval(1)))
    }

    @Test("die Pause hat einen benannten Grund fuers Log")
    func pausedHasAReason() {
        #expect(FreeCatalog.failureReason(CatalogHostGuard.Paused(host: "archive.org"))
                == "host paused (archive.org)")
    }

    /// Das EINE Gedaechtnis: was der Erstbezug notiert, sieht die
    /// Fach-Abfrage, und umgekehrt.
    @Test("das Gedaechtnis ist eines fuer alle Wege")
    @MainActor
    func oneLedgerForAllPaths() {
        HostDistance._reset()
        #expect(!HostDistance.isBlocked("archive.org"))
        HostDistance.note("archive.org")
        #expect(HostDistance.isBlocked("archive.org"))
        #expect(!HostDistance.isBlocked("gutendex.com"))
        #expect(!HostDistance.isBlocked("archive.org",
                                        now: Date().addingTimeInterval(CatalogHostGuard.blockSeconds + 1)))
        HostDistance._reset()
    }
}
#endif
