// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
@testable import Maer

// Tests fill a row store the way the app writes it: one diff against the
// rows that stand, in one transaction. The app itself has no whole-stock
// replacement; a row this build can not read stays, as it does in the app.

extension PodcastRowStore {
    @discardableResult
    func replaceAll(_ shows: [PodcastShow]) async throws -> Counts {
        try await apply(PodcastRowDiff.compute(previous: try await loadAll(), current: shows))
    }
}

extension LibraryRowStore {
    @discardableResult
    func replaceAll(_ cache: LibraryDiskCache) async throws -> Counts {
        try await apply(LibraryRowDiff.compute(previous: try await loadAll(), current: cache))
    }
}

extension KeyedRowStore {
    @discardableResult
    func replaceAll(_ values: [String: Value]) async throws -> Int {
        try await apply(previous: try await loadAll() ?? [:], current: values).upserted
    }
}
