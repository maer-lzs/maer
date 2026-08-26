// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// The mass-delete guard warning is STICKY. It survives until a later
/// clean sync clears it, so a one-off guard trip is not lost the moment the
/// podcast tab is reopened (which fires another, warning-free reconcile).
@MainActor
struct GPodderStickyWarningTests {
    private func stored(warning: String?) -> GPodderSync.StoredReport {
        GPodderSync.StoredReport(date: Date(), report: GPodderSync.Report(),
                                 warning: warning, warningDate: warning == nil ? nil : Date())
    }

    @Test("a new warning replaces the old one")
    func newWarningReplaces() {
        var r = GPodderSync.Report(); r.warning = "blocked 5 removals"
        #expect(GPodderSync.stickyWarning(new: r, previous: stored(warning: "old")).warning == "blocked 5 removals")
    }

    @Test("a clean sync (no warning, no error) clears the sticky warning")
    func cleanSyncClears() {
        let r = GPodderSync.Report()
        #expect(GPodderSync.stickyWarning(new: r, previous: stored(warning: "old")).warning == nil)
    }

    @Test("a failed sync (error) keeps the previous warning instead of hiding it")
    func failedSyncKeeps() {
        var r = GPodderSync.Report(); r.error = "offline"
        #expect(GPodderSync.stickyWarning(new: r, previous: stored(warning: "old")).warning == "old")
    }

    @Test("no previous + clean sync → no warning")
    func nothingToKeep() {
        #expect(GPodderSync.stickyWarning(new: GPodderSync.Report(), previous: nil).warning == nil)
    }
}
#endif
