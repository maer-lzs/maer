// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The fingerprint this device computes for a service's key, against the
/// values the service's own function prints. Two constructions of the same
/// derivation in two languages are only known to agree by fixed vectors;
/// a self comparison on each side would let both drift together.
struct ServiceKeyFingerprintTests {
    /// Computed with `core.identity.fingerprint` in the service repository
    /// on 2026-09-17, and standing in its witnesses too.
    static let vectors: [(bytes: Data, written: String)] = [
        (Data(repeating: 0x07, count: 32), "9ER6-Z3JE-79VH-BMG1-TNSX-1AJ2"),
        (Data(0..<32), "CC6W-TAB6-RGSP-D48J-AH4B-QCJV"),
        (Data(repeating: 0x00, count: 32), "CSM7-NBFR-CAYQ-EV4F-R65R-X7WE"),
        (Data(repeating: 0xFF, count: 32), "NYB1-6XGF-E9HN-ZFDM-99D0-MRY3"),
    ]

    @Test("four keys print here what the service prints for them")
    func theVectorsAgreeWithTheService() {
        for vector in Self.vectors {
            #expect(ServiceKeyFingerprint.written(for: vector.bytes) == vector.written)
        }
    }

    @Test("six groups of four, from the alphabet without I, L, O and U")
    func sixGroupsOfFourFromTheAlphabet() throws {
        let written = try #require(ServiceKeyFingerprint.written(for: Data(repeating: 0x42, count: 32)))
        let groups = written.split(separator: "-")
        #expect(groups.count == 6)
        #expect(groups.allSatisfy { $0.count == 4 } == true)
        let alphabet = Set(ServiceKeyFingerprint.alphabet)
        #expect(written.filter { $0 != "-" }.allSatisfy { alphabet.contains($0) } == true)
        for confusable in "ILOU" { #expect(!alphabet.contains(confusable)) }
    }

    @Test("a key that is not 32 bytes gets no fingerprint")
    func aKeyOfTheWrongLengthGetsNoFingerprint() {
        #expect(ServiceKeyFingerprint.written(for: Data(repeating: 7, count: 31)) == nil)
        #expect(ServiceKeyFingerprint.written(for: Data(repeating: 7, count: 33)) == nil)
        #expect(ServiceKeyFingerprint.written(for: Data()) == nil)
    }

    @Test("two keys print differently, one byte of difference is enough")
    func oneByteApartPrintsDifferently() {
        var other = Data(repeating: 7, count: 32)
        other[31] = 8
        #expect(ServiceKeyFingerprint.written(for: other) != "9ER6-Z3JE-79VH-BMG1-TNSX-1AJ2")
    }
}
#endif
