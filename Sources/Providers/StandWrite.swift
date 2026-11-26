// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

@MainActor
enum StandWrite {
    static func allowed(itemId: String, provider: any AudioProvider) -> Bool { true }
}
