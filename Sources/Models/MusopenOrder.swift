// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The order of the Musopen page.
nonisolated enum MusopenOrder {
    static func isSinglePart(_ title: String) -> Bool { false }

    static func composerKey(author: String?, title: String) -> String { "" }

    static func ordered<T>(_ items: [T], title: (T) -> String, composer: (T) -> String?) -> [T] { items }
}
