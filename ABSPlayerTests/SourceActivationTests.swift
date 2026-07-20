// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Testing
@testable import ABSPlayer

/// TF (bib-toggles): the two-level activation invariant — a source is effective
/// only when BOTH its tab master and its own toggle are on. All the provider
/// `…Active` accessors compose this one function.
struct SourceActivationTests {
    @Test("effective = tab master AND source toggle")
    func effective() {
        #expect(SourceActivation.effective(tabEnabled: true, sourceEnabled: true))
        #expect(!SourceActivation.effective(tabEnabled: false, sourceEnabled: true))
        #expect(!SourceActivation.effective(tabEnabled: true, sourceEnabled: false))
        #expect(!SourceActivation.effective(tabEnabled: false, sourceEnabled: false))
    }
}
#endif
