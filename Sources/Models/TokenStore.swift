// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

nonisolated enum TokenStore {
    enum Outcome: Equatable, Sendable { case new, old, none }
    static func store(_ token: String, save: (String) -> Bool, read: () -> String?) -> Outcome { .new }
}
