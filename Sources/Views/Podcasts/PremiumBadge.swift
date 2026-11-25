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
    var size: CoverMarkSize.Class = .tile
    @Environment(\.dynamicTypeSize) private var type

    var body: some View {
        let diameter = CoverMarkSize.diameter(.tile, type)
        switch lock {
        case .refused:
            Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                .font(.system(size: diameter * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(GlyphTone.alert))
                .accessibilityLabel(Text("Access refused"))
        case .premium:
            Image(systemName: "lock.fill")
                .font(.system(size: diameter * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .glyphDisc()
                .accessibilityLabel(Text("Premium Feed"))
        case .none:
            EmptyView()
        }
    }
}
