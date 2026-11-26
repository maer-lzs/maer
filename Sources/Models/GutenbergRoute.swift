// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

nonisolated enum GutenbergRoute {
    static func mirror(of url: URL) -> URL? { nil }
    static func asksMirror(status: Int?, resting: Bool) -> Bool { false }
}

/// Gutenberg did not answer, its main server nor its mirror.
nonisolated struct GutenbergUnavailable: Error, Equatable {}
