// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

nonisolated enum CatalogCoverRule {
    static let absentFor: Double = 30 * 24 * 3600

    static func shows(coverURL: URL?, isAbsent: (URL) -> Bool) -> Bool { true }

    static func stillAbsent(since: Double, now: Double) -> Bool { true }

    static func isCatalogCover(_ url: URL) -> Bool { false }
}

extension CatalogCoverRule {
    @MainActor
    static func browsable(_ items: [LibraryItem], register: FreeCatalogProvider = .shared) -> [LibraryItem] {
        items
    }
}
