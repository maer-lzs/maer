// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What the Audiobookshelf row of the next-steps card leads to. The card
/// stands in two hosts, the first-start sheet and the settings, and both
/// must send a signed-in person to the source page, never to the empty
/// login form; the sheet used to hand out the form unconditionally.
nonisolated enum NextStepsRules {
    enum ABSDestination: Equatable, Sendable {
        /// No session yet: the form that makes one.
        case loginForm
        /// A session stands: the source page with its address and log-out.
        case sourcePage
    }

    static func absDestination(isLoggedIn: Bool) -> ABSDestination {
        isLoggedIn ? .sourcePage : .loginForm
    }
}
