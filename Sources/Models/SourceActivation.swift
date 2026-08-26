// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// TF (bib-toggles): the two-level library gating invariant. A source is
/// EFFECTIVELY ACTIVE — makes server calls and contributes its tab — only when
/// BOTH its tab master (media type) and its own source toggle are on:
/// `effective = tabEnabled ∧ sourceEnabled`. THE one rule; every
/// provider's availability/call-gate derives from it via the `…Active`
/// accessors on `AppStorageKeys`. Foundation-only, pure, tested.
nonisolated enum SourceActivation {
    static func effective(tabEnabled: Bool, sourceEnabled: Bool) -> Bool {
        tabEnabled && sourceEnabled
    }
}
