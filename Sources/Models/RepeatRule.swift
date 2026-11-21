// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Repeat in music: off, the list, one song. A tap goes round in this
/// order, as in the system's music app; the state stays until someone
/// changes it.
nonisolated enum RepeatMode: String, CaseIterable, Sendable {
    case off
    case all
    case one

    var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    /// The stored value; one this build does not know is off.
    static func stored(_ raw: String?) -> RepeatMode {
        raw.flatMap(RepeatMode.init(rawValue:)) ?? .off
    }
}

/// What repeat makes of a title's end, music only.
nonisolated enum RepeatRule {
    enum Step: Equatable, Sendable {
        /// The same song again.
        case same
        /// What was started, from its first title.
        case restart
        /// The usual way on: orders, the rest of what was started, the
        /// medium's own continuation.
        case cascade
    }

    /// One song repeats at its natural end, before any order; a skip goes
    /// on. The list starts again only when nothing else follows, so the
    /// orders of Up Next and the rest play first.
    static func step(mode: RepeatMode, isMusic: Bool, natural: Bool, cascadeFound: Bool, wholeCount: Int) -> Step {
        guard isMusic else { return .cascade }
        switch mode {
        case .one: return natural ? .same : .cascade
        case .all: return !cascadeFound && wholeCount > 0 ? .restart : .cascade
        case .off: return .cascade
        }
    }
}
