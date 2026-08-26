// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// P13: THE premium lock — the anatomy existed twice byte-identically in
/// `PodcastComponents` and was missing exactly where the user looked: Start's
/// "Latest Episodes". One component instead of copies (Regel 2), so the next
/// surface inherits the mark rather than forgetting it.
///
/// **Cell cost:** the caller passes the already-resolved `isPremium` — the
/// classification is a keychain/UserDefaults lookup, and resolving it PER
/// CELL is what the grid's "Paket B" comment warns about. Grids resolve the
/// set once per render and ask it here.
struct PremiumLockBadge: View {
    let isPremium: Bool

    var body: some View {
        if isPremium {
            Image(systemName: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.white)
                .padding(5)
                .background(Circle().fill(.black.opacity(0.55)))
                .padding(6)
                .accessibilityLabel(Text("Premium Feed"))
        }
    }
}

extension View {
    /// The badge at its canonical place: bottom-trailing on the artwork.
    func premiumLock(_ isPremium: Bool) -> some View {
        overlay(alignment: .bottomTrailing) { PremiumLockBadge(isPremium: isPremium) }
    }
}
