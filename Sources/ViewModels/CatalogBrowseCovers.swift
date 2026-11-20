// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

extension CatalogCoverRule {
    /// The entries of a browse page or shelf that show: those whose cover
    /// the register names and that did not answer "none here". Asked by
    /// the builders after the register took the entries, so the cover of a
    /// LibriVox reading and of a Jamendo song is known; order is kept. A
    /// page on screen is not asked again: a cover that turns out absent
    /// while it shows leaves its tile standing until the next build.
    @MainActor
    static func browsable(_ items: [LibraryItem], register: FreeCatalogProvider) -> [LibraryItem] {
        items.filter { shows(coverURL: register.coverURL(forItemId: $0.id), isAbsent: { AbsentCovers.contains($0) }) }
    }
}
