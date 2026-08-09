// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
@testable import ABSPlayer

/// Y60: the canonical offline-unavailable predicate shared by every downloadable
/// media row (queue, browse deck, book/podcast rows).
struct MediaAvailabilityTests {
    @Test("offline + not downloaded → unavailable; any other combination → available")
    func offlineUnavailable() {
        #expect(MediaAvailability.offlineUnavailable(isConnected: false, isDownloaded: false))
        #expect(!MediaAvailability.offlineUnavailable(isConnected: false, isDownloaded: true))
        #expect(!MediaAvailability.offlineUnavailable(isConnected: true, isDownloaded: false))
        #expect(!MediaAvailability.offlineUnavailable(isConnected: true, isDownloaded: true))
    }
}
#endif
