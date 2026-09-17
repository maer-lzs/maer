// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The ceiling of a carrier with room limits, reckoned BEFORE a write. The
/// key-value store holds one megabyte for everything and refuses a write
/// that does not fit without a word; the watch after the fact sees only
/// the refusal. So the carriers with a ceiling ask here first, with the
/// bytes the value takes beside what the store already holds, and refuse
/// out loud, with the numbers, when it does not fit.
nonisolated enum RoomLimit {
    /// The shared megabyte of the key-value store.
    static let potLimitBytes = ForeignImportPreview.potLimitBytes

    /// What a pre-check found: the bytes the write would take, what the
    /// store holds beside it, and the ceiling.
    struct Reckoning: Equatable, Sendable {
        var bytes: Int
        var otherBytes: Int
        var limit: Int
        var total: Int { bytes + otherBytes }
        var fits: Bool { total <= limit }
    }

    /// Whether `bytes` fit beside `otherBytes` under `limit`.
    static func reckon(bytes: Int, otherBytes: Int, limit: Int = potLimitBytes) -> Reckoning {
        Reckoning(bytes: bytes, otherBytes: otherBytes, limit: limit)
    }

    /// The bytes a property-list value takes in the store, binary form, or
    /// nil when it cannot be serialised at all. A caller that gets nil
    /// knows nothing and lets the write go; the store's own refusal is
    /// then the second watch.
    static func bytes(ofPropertyList value: Any) -> Int? {
        // tragbar, weil ein nicht kodierbarer Wert hier nur "unbekannt" heisst und die Nach-Wache bleibt
        (try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0))?.count
    }

    /// The bytes the store holds under every key but `key`.
    static func otherBytes(in store: [String: Any], besides key: String) -> Int {
        bytes(ofPropertyList: store.filter { $0.key != key }) ?? 0
    }
}
