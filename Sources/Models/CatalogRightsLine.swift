// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The one rights line of a catalogue title, for every surface that names
/// its rights (`CatalogRightsSection`).
nonisolated enum CatalogRightsLine: Equatable {
    case jamendo
    case stated(String)
    case publicDomain
    case termsApply(year: String)
    case unknown

    static func of(itemId: String, licence: String?, year: String?,
                   currentYear: Int = Calendar.current.component(.year, from: Date())) -> CatalogRightsLine {
        .unknown
    }

    /// Whether the line carries the seal.
    var sealed: Bool { false }
}
