// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

@MainActor
enum SmartFolders {
    @discardableResult
    static func create(_ suggestions: [SmartFolderSuggestion.Suggestion], ticked: Set<String>, in store: MaerPlaylists) -> [MaerPlaylists.Playlist] { [] }
}
