// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation

/// Holds a fake cloud's next `modify` open after it was called and before
/// it stores anything, until the witness lets it go. The one way to open
/// the window in which a second write lands while the first is in flight;
/// a fake that never suspends can never show what a carrier does then.
@MainActor
final class ModifyHold {
    var holdNext = false
    private var held: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?

    /// First thing in a fake's `modify`: suspends there when armed.
    func enter() async {
        if holdNext {
            holdNext = false
            await withCheckedContinuation { continuation in
                held = continuation
                waiting?.resume()
                waiting = nil
            }
        }
    }

    /// Returns once the held `modify` has been entered.
    func entered() async {
        if held != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func release() {
        let go = held
        held = nil
        go?.resume()
    }
}
#endif
