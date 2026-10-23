// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// THE premium lock. The anatomy existed twice byte-identically in
/// `PodcastComponents` and was missing exactly where the user looked: Start's
/// "Latest Episodes". One component instead of copies, so the next
/// surface inherits the mark rather than forgetting it.
///
/// It draws what `PodcastSubscriptions.lock(feedURL:)` answered (`FeedLock`),
/// with no default: a surface cannot show the premium lock and leave the
/// refusal out.
///
/// **Cell cost:** the caller passes the already-resolved lock. The
/// classification is a keychain/UserDefaults lookup, and resolving it PER
/// CELL is what the grid's cell-cost rule warns about. Grids resolve the
/// locks once per render and hand them here.
struct PremiumLockBadge: View {
    let lock: FeedLock

    var body: some View {
        switch lock {
        case .refused:
            Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                .font(.caption2)
                .foregroundStyle(.white)
                .padding(5)
                .background(Circle().fill(Color.orange))
                .padding(6)
                .accessibilityLabel(Text("Access refused"))
        case .premium:
            Image(systemName: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.white)
                .padding(5)
                .glyphDisc()
                .padding(6)
                .accessibilityLabel(Text("Premium Feed"))
        case .none:
            EmptyView()
        }
    }
}

extension View {
    /// The badge at its canonical place: bottom-trailing on the artwork.
    func premiumLock(_ lock: FeedLock) -> some View {
        overlay(alignment: .bottomTrailing) { PremiumLockBadge(lock: lock) }
    }
}
