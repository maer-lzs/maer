// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import SwiftUI
import Testing
@testable import Maer

/// A show among the search hits carries the lock of its feed, as on the
/// desktop and as the deck already does; an episode hit carries none, as
/// on the desktop. The lock is asked once per search, not per row, and
/// drawn in the size of a row's marks.
@MainActor
struct SearchLockTests {
    static let locks: [String: FeedLock] = ["https://premium.example/feed": .premium,
                                            "https://refused.example/feed": .refused]

    @Test("show hits carry their feed's lock, episode hits none")
    func showHitsCarryTheLock() {
        let hits = [
            SearchResult(id: "https://premium.example/feed", kind: .show, title: "Premium Show"),
            SearchResult(id: "https://refused.example/feed", kind: .show, title: "Refused Show"),
            SearchResult(id: "https://free.example/feed", kind: .show, title: "Free Show"),
            SearchResult(id: "rss:premium:1", kind: .episode, title: "An Episode", subtitle: "Premium Show"),
            // A directory hit nobody follows: no lock, even for a feed
            // address the lock question would know.
            SearchResult(id: "https://premium.example/feed", kind: .catalogShow, title: "In the Directory"),
        ]
        let locked = SearchHitLock.locked(hits) { Self.locks[$0] ?? .none }
        #expect(locked.map(\.lock) == [.premium, .refused, .none, .none, .none])
    }

    @Test("the lock of a row has the side of a row's marks, at the standard size and at AX3", arguments: [DynamicTypeSize.large, .accessibility3])
    func rowSize(_ type: DynamicTypeSize) {
        let side = CoverMarkSize.diameter(.row, type)
        for lock in [FeedLock.premium, .refused] {
            let size = CoverMarkSizeTests.size(PremiumLockBadge(lock: lock, size: .row), type)
            #expect(abs(size.width - side) <= 0.5 && abs(size.height - side) <= 0.5, "\(lock) at \(type): \(size), the rule says \(side)")
        }
    }

    @Test("Fence: the provider asks the lock once per search, the hit row passes it on", .needsTheSources)
    func wiring() throws {
        func source(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        #expect(try source("Sources/Providers/ProviderSearch.swift").contains("SearchHitLock.locked("))
        let screen = try source("Sources/Views/SearchScreen.swift")
        #expect(screen.contains("lock: result.lock"), "the hit row draws no lock")
        let row = try source("Sources/Views/MediaRowContent.swift")
        #expect(row.contains("PremiumLockBadge(lock: lock, size: .row)"))
    }
}
#endif
