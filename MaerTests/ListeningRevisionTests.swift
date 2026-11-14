// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Combine
import Foundation
@testable import Maer

/// The seam counts events and announces each one; the rows that hang on
/// it recompute per bump, never per tick.
struct ListeningRevisionTests {
    @Test("Every bump counts once and announces itself once")
    @MainActor
    func bumpCountsAndAnnounces() {
        let revision = ListeningRevision()
        var announced = 0
        let sink = revision.objectWillChange.sink { _ in announced += 1 }
        defer { sink.cancel() }
        let before = revision.value
        revision.bump("test start")
        revision.bump("test pause")
        #expect(revision.value == before + 2)
        #expect(announced == 2)
    }

    /// The podcast store is one of the writers: its bump reaches the seam,
    /// and the Podcasts tab scope moves with it (the store used to be the
    /// scope's only listening trigger).
    @Test("The podcast store triggers the seam")
    @MainActor
    func podcastStoreBumpsTheSeam() {
        let before = ListeningRevision.shared.value
        PodcastProgressStore.shared.reload()
        #expect(ListeningRevision.shared.value == before + 1)
    }
}
#endif
