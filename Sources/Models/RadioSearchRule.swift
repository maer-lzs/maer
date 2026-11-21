// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What a search asks of radio: nothing while the Radio tab is off; the
/// saved and hand-entered stations while it is on; the Radio Browser
/// directory too only while the Radio Catalog switch is on.
nonisolated enum RadioSearchRule {
    enum Scope: Equatable, Sendable {
        case off
        case ownStations
        case withCatalog
    }

    static func scope(tabOn: Bool, catalogOn: Bool) -> Scope {
        guard tabOn else { return .off }
        return catalogOn ? .withCatalog : .ownStations
    }
}
