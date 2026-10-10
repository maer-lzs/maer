// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Audiobookshelf as the first AudioProvider. The conformance is deliberately
/// almost empty: the protocol was cut along the existing APIClient surface. A
/// dedicated wrapper type only comes once a second provider surfaces real
/// conflicts.
extension APIClient: AudioProvider {
    var providerId: String { "abs" }

    var keepsMarksOnDevice: Bool { false }
    var capabilities: ProviderCapabilities {
        [.progressSync, .bookmarks, .passwordLogin, .downloadable]
    }

    var streamAuthHeaders: [String: String] {
        guard let token, !token.isEmpty else { return [:] }
        return ["Authorization": "Bearer \(token)"]
    }
}
