// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The one rights line of a catalogue title, for every surface that names
/// its rights (`CatalogRightsSection`): the licence the source states,
/// else the year speaks (`FreeCatalog.rightsNote`); never a blanket badge
/// (an Old-Time-Radio item can be CC-BY-NC-ND, and a checkmark IS an
/// assertion). Jamendo's terms ask for their own line.
nonisolated enum CatalogRightsLine: Equatable {
    case jamendo
    case stated(String)
    case publicDomain
    case termsApply(year: String)
    case unknown

    static func of(itemId: String, licence: String?, year: String?,
                   currentYear: Int = Calendar.current.component(.year, from: Date())) -> CatalogRightsLine {
        if itemId.hasPrefix(FreeCatalog.jamendoPrefix) { return .jamendo }
        // "Rights not stated" is no statement.
        if let licence, licence != FreeCatalog.unstatedRights {
            return .stated(licence)
        }
        switch FreeCatalog.rightsNote(year: year, currentYear: currentYear) {
        case .publicDomain: return .publicDomain
        case .termsApply(let year): return .termsApply(year: year)
        case .unknown: return .unknown
        }
    }

    /// Whether the line carries the seal: a statement or the law, never
    /// the terms of a country or an unstated right, where a checkmark would
    /// be a claim of its own.
    var sealed: Bool {
        switch self {
        case .jamendo, .stated, .publicDomain: true
        case .termsApply, .unknown: false
        }
    }
}
