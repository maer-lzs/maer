// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import CryptoKit
import Foundation

/// Navidrome 0.64 gives every song, playlist and user a new id, computed
/// from the old one by a fixed rule (`canonicalID` in its migration
/// `20260720015443_uniform_canonical_ids.go`). The server keeps no table of
/// old to new and answers an old id with "not found" (code 70), so whoever
/// stores ids recomputes them. This is that rule, value for value.
///
/// Every new id is 22 characters of base 62 in Go's digit order (digits,
/// then lower case, then upper case), left padded with zeros, for a 128-bit
/// value. An old id becomes:
/// - 22 characters that read as at most 128 bits: unchanged;
/// - 22 characters that read as more (the random ids before 0.64): the MD5
///   of the old text;
/// - 32 hex characters: the same 128 bits re-encoded;
/// - a 36 character UUID: the same 128 bits re-encoded;
/// - anything else: unchanged.
/// On an id that is already new the rule is the identity, so applying it
/// twice is applying it once.
nonisolated enum NavidromeID {
    /// Go's base 62 digits, in Go's order.
    static let digits: [UInt8] = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)

    /// The length of every new id.
    static let length = 22

    /// The new id for an old one.
    static func canonical(_ id: String) -> String {
        let bytes = Array(id.utf8)
        switch bytes.count {
        case length:
            switch base62(bytes) {
            case .invalid, .fits: return id
            case .overflows: return encode(Array(Insecure.MD5.hash(data: Data(bytes))))
            }
        case 32:
            guard let value = hex(bytes[...]) else { return id }
            return encode(value)
        case 36:
            let dashes = [8, 13, 18, 23]
            guard dashes.allSatisfy({ bytes[$0] == UInt8(ascii: "-") }) else { return id }
            let packed = bytes.enumerated().filter { !dashes.contains($0.offset) }.map(\.element)
            guard let value = hex(packed[...]) else { return id }
            return encode(value)
        default:
            return id
        }
    }

    /// The reading of a 22 character id as a number in base 62.
    enum Reading: Equatable {
        /// A character outside the digits: not a number, kept as it is.
        case invalid
        /// At most 128 bits.
        case fits(UInt128)
        /// More than 128 bits.
        case overflows
    }

    static func base62(_ bytes: [UInt8]) -> Reading {
        var value: UInt128 = 0
        var overflowed = false
        for byte in bytes {
            guard let digit = digits.firstIndex(of: byte) else { return .invalid }
            if overflowed { continue }
            let (times, o1) = value.multipliedReportingOverflow(by: 62)
            let (plus, o2) = times.addingReportingOverflow(UInt128(digit))
            if o1 || o2 { overflowed = true } else { value = plus }
        }
        return overflowed ? .overflows : .fits(value)
    }

    /// 32 hex characters, either case, as the 16 bytes they spell.
    static func hex(_ bytes: ArraySlice<UInt8>) -> [UInt8]? {
        guard bytes.count == 32 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(16)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { return nil }
            out.append(high << 4 | low)
            index += 2
        }
        return out
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// 16 bytes, big endian, as a new id.
    static func encode(_ bytes: [UInt8]) -> String {
        var value: UInt128 = 0
        for byte in bytes { value = value << 8 | UInt128(byte) }
        var out: [UInt8] = []
        while value > 0 {
            out.append(digits[Int(value % 62)])
            value /= 62
        }
        while out.count < length { out.append(UInt8(ascii: "0")) }
        return String(decoding: out.reversed(), as: UTF8.self)
    }
}

/// When the rule applies: only to a server that calls itself Navidrome and
/// reports a version from 0.64.0 on. Any other Subsonic server (Gonic,
/// Airsonic, Nextcloud Music) keeps its own ids, and a missing or
/// unreadable version means the server is not touched.
nonisolated enum NavidromeIDRule {
    static let firstVersion = [0, 64, 0]

    static func applies(type: String?, version: String?) -> Bool {
        guard type?.lowercased() == "navidrome", var parts = versionParts(version) else { return false }
        // "0.64" is 0.64.0: a shorter list would sort before it.
        while parts.count < firstVersion.count { parts.append(0) }
        return parts.lexicographicallyPrecedes(firstVersion) == false
    }

    /// The leading numbers of a version text: "0.64.2 (38dc2727)" reads
    /// [0, 64, 2]. At least major and minor, or nil.
    static func versionParts(_ raw: String?) -> [Int]? {
        guard let raw else { return nil }
        let head = raw.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        let parts = head.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count >= 2, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }
}
