// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

@MainActor
final class EstimatedPlace {
    struct Place: Equatable, Sendable {
        let track: Int
        let offset: Double
    }

    init(database: MaerDatabase?) {}

    func note(_ itemId: String, track: Int, offset: Double, atMs: Double) {}
    func place(_ itemId: String) -> Place? { nil }
    func forget(_ itemId: String) {}

    static func position(of place: Place, tracks: [ABSAudioTrack]) -> Double { 0 }
}
