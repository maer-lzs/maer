// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Serializes detached file writes: every `write` awaits the previous one, so
/// two overlapping writes can never interleave on the same file. Submissions
/// happen on the main actor (deterministic order); the encode/IO runs detached.
/// Used by the podcast store — extracted so the chain semantics are testable.
@MainActor
final class SerializedWriteChain {
    private var chain: Task<Void, Never>?

    /// Queue a write. `makeData` runs OFF-main inside the chain (encode there,
    /// pass value snapshots in); the write is atomic (temp file + rename).
    func write(to url: URL, makeData: @escaping @Sendable () -> Data?) {
        let previous = chain
        chain = Task.detached(priority: .utility) {
            await previous?.value
            guard let data = makeData() else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Waits until every queued write has finished (tests, teardown).
    func flush() async {
        await chain?.value
    }
}
