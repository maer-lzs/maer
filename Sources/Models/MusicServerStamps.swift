// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Synchronization

/// The kinds of rows a device keeps for a title on its own.
nonisolated enum MusicRowKind: String, CaseIterable, Codable, Sendable {
    case stand, download, queue, context, history
}

/// Which Subsonic server a device-only row of a Subsonic title was written
/// under. The ids carry no server, and two servers of one kind can hand out
/// the same id for two titles; the stamp lets a row written under one
/// server read as absent under another, and come back with its server.
nonisolated struct MusicServerStamps: Codable, Equatable, Sendable {
    /// Kind → id → server key.
    private(set) var stamps: [String: [String: String]] = [:]

    static func key(of address: String) -> String? { nil }
    static func isStamped(_ itemId: String) -> Bool { false }
    mutating func stamp(_ itemId: String, kind: MusicRowKind, server: String?) {}
    func isElsewhere(_ itemId: String, kind: MusicRowKind, current: String?) -> Bool { false }
    func shown(_ ids: [String], kind: MusicRowKind, current: String?) -> [String] { ids }
    mutating func rekey(_ map: (String) -> String) {}
}

/// The device's register, held per defaults object.
nonisolated enum MusicServerStampBook {
    static func stamp(_ itemId: String, kind: MusicRowKind, in defaults: UserDefaults = .standard) {}
    static func isElsewhere(_ itemId: String, kind: MusicRowKind, in defaults: UserDefaults = .standard) -> Bool { false }
    static func shown(_ ids: [String], kind: MusicRowKind, in defaults: UserDefaults = .standard) -> [String] { ids }
    static func rekey(_ map: (String) -> String, in defaults: UserDefaults = .standard) {}
}

/// The entries of a travelling list a device shows.
nonisolated enum PlaylistShown {
    static func entries(_ ids: [String], reason: (String) -> UnavailableReason?) -> [String] { ids }
}
