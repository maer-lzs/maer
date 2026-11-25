// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

enum MusopenReload {
    enum Outcome: Equatable {
        case notNeeded, readFailed, superseded, nothingFollows
        case started(String)
    }

    @MainActor
    static func run(title: String, readToEnd: Bool, read: () async -> Bool, stillEnded: () -> Bool,
                    resolve: () -> String?, start: (String) async -> Void, log: (String) -> Void) async -> Outcome {
        .notNeeded
    }
}
