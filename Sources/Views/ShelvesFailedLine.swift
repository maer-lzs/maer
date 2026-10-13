// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The line a catalog page shows when its genre shelves could not be asked.
/// A shelf that could not be ASKED must not look like a shelf the source does
/// not HAVE: both leave the row absent, and only this line tells them apart.
/// Shared by every page that loads genre shelves, so the rule and the
/// sentence are the same on each.
struct ShelvesFailedLine: View {
    let retry: () -> Void

    /// Shown only when nothing at all arrived. A partial failure leaves the
    /// shelves that did, and those speak for the page.
    nonisolated static func isShown(arrived: Int, failed: Int) -> Bool {
        arrived == 0 && failed > 0
    }

    var body: some View {
        LoadFailedView(form: .line, sentence: "Genres could not be loaded.", retry: retry)
            .padding(.horizontal)
    }
}
