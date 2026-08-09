// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
@testable import ABSPlayer

/// ABS hardening: a silent foreground re-fetch must not SHRINK the library on a
/// partial/hiccuped answer (which would then be persisted). It is accepted only
/// when not smaller than the cache.
@MainActor
struct LibraryRefreshPlausibilityTests {
    private func items(_ n: Int) -> [LibraryItem] {
        (0..<n).map { id in
            LibraryItem(id: "b\(id)", media: LibraryItemMedia(
                metadata: LibraryItemMetadata(title: "b\(id)", authorName: nil, narratorName: nil,
                                              seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                duration: 100, chapters: nil, tracks: nil), addedAt: nil)
        }
    }

    @Test func implausibleShrinkKeepsCache() {
        let cached = items(50)
        let fresh = items(3)          // server hiccup / partial 2xx
        #expect(LibraryViewModel.plausibleFreshItems(fresh, cached: cached).count == 50)
    }

    @Test func genuineGrowthIsTaken() {
        let cached = items(50)
        let fresh = items(60)
        #expect(LibraryViewModel.plausibleFreshItems(fresh, cached: cached).count == 60)
    }

    @Test func equalCountIsTaken() {
        // Same size (e.g. edited metadata, no count change) → take the fresh one.
        let cached = items(10)
        let fresh = items(10)
        let out = LibraryViewModel.plausibleFreshItems(fresh, cached: cached)
        #expect(out.count == 10)
        #expect(out.first?.id == fresh.first?.id)
    }
}
#endif
