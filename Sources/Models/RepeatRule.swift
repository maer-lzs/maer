// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Repeat in music: off, the list, one song.
nonisolated enum RepeatMode: String, CaseIterable, Sendable {
    case off
    case all
    case one

    var next: RepeatMode { self }

    static func stored(_ raw: String?) -> RepeatMode { .off }
}

/// What repeat makes of a title's end.
nonisolated enum RepeatRule {
    enum Step: Equatable, Sendable {
        case same
        case restart
        case cascade
    }

    static func step(mode: RepeatMode, isMusic: Bool, natural: Bool, cascadeFound: Bool, wholeCount: Int) -> Step { .cascade }
}
