// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// ONE question: run this when the scroll is at rest.
///
/// Content that can grow or move sections must not arrive under a moving
/// finger. Sections appearing mid-gesture read as a hitch even at a perfect
/// frame rate, so such an update is applied at once while things are calm
/// and queued while they are not. That rule is the same for every tab and
/// lives behind the bottom bar, which is the surface that knows when the
/// scroll rests.
///
/// It lives here as its own name because the CALLERS should not know that.
/// Twenty-two of them asked `BottomBarState.shared` directly, and fourteen
/// of those are stores and view models: a music view model that knows a
/// bottom bar exists is the layering mistake, not the queueing.
///
/// Be honest about what this buys, because the count will drop and the
/// count does not say it: twenty-two grips collapse into one, but nothing
/// gets faster and nothing becomes replaceable. The gain is the name.
///
/// The deeper cut is the other way round, and it stays a named rest with a
/// NUMBER rather than an intention: a store hands its fresh value OUT and
/// the VIEW decides when to apply it. That turns fourteen call sites around
/// and belongs with the tab cut, where those view models are opened anyway.
/// `ScrollCalmFenceTests` counts them per enclosing type and lets the number
/// only fall; at zero that cut is done.
@MainActor
enum ScrollCalm {
    /// Apply now if the scroll rests, else when it does.
    static func run(_ block: @escaping @MainActor () -> Void) {
        BottomBarState.shared.runWhenCalm(block)
    }
}
