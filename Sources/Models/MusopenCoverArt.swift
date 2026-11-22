// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The drawn cover of a Musopen recording.
nonisolated enum MusopenCoverArt {
    static let palette: [[Double]] = []

    static func applies(to itemId: String) -> Bool { false }

    static func colourIndex(composer: String?) -> Int { 0 }

    static func colour(composer: String?) -> [Double] { [0, 0, 0] }

    static func lines(title: String, composer: String?) -> (composer: String?, work: String) {
        (nil, "")
    }
}
