// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// One send of a cloud carrier in flight at a time. Every write starts a
/// send, and two of them in flight at once could land in the other order:
/// the cloud's save policy takes the last write, so the OLDER batch would
/// overwrite the newer one. Each send waits for the one before it.
/// Found for the stand carrier by the witness that holds a `modify` open;
/// the choice, playlist and stats carriers had the same form without it.
@MainActor
final class SendChain {
    private var last: Task<Int, Never>?

    /// Runs `send` after every send started before it, and answers its
    /// count.
    @discardableResult
    func run(_ send: @escaping @MainActor () async -> Int) async -> Int {
        let previous = last
        let run = Task { @MainActor in
            _ = await previous?.value
            return await send()
        }
        last = run
        return await run.value
    }
}
