// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Two envelopes as iOS seals them, kept as a file that Android opens too.
/// The file is a RECORD of what `FeedAuthCrypto.seal` wrote once (the code
/// envelope 1 and the feed envelope 2, plus a foreign code that must not
/// open); no witness seals anew, so a drift in the envelope (info text,
/// field names, tag order, base64) tears here before two halves of one
/// account stop reading each other.
struct FeedAuthEnvelopeFixtureTests {
    /// The cases live in `Fixtures/Shared/feedauth/umschlaege.json`, read by
    /// Swift and Kotlin alike.
    nonisolated static let envelopes = SharedCases.cases("umschlaege", area: "feedauth")

    @Test("shared cases: umschlaege carries three cases")
    func envelopeCasesLoaded() {
        #expect(Self.envelopes.count == 3)
    }

    @Test("shared cases: every envelope opens with its key to the plaintext of the file, the foreign code does not open", arguments: envelopes)
    func everyEnvelopeOpensAsTheFileSays(_ c: SharedCase) throws {
        let input = try c.value("input")
        let envelope = Data(try #require(input["umschlag"]?.string).utf8)
        let code = input["code"]?.string.flatMap(DeviceLinkCode.normalized)
        let feed = input["feed_hex"]?.string.flatMap(Self.bytes)
        let opening = FeedAuthCrypto.open(envelope, code: code, feed: feed)
        if let expected = c["expect"]?.string {
            #expect(opening == .plaintext(Data(expected.utf8)), "\(c.slug)")
        } else {
            #expect(opening == .sealedForAnother, "\(c.slug)")
        }
    }

    /// The file is a record, never regenerated: no witness of this file
    /// seals. Read from the source so the rule cannot drift with a refactor.
    @Test("the file is a record: no witness of this file seals anew", .needsTheTests)
    func theFileIsARecordNotARegeneration() throws {
        let text = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
        #expect(!text.contains("FeedAuthCrypto.seal" + "("), "this witness seals; the file would then measure itself")
    }

    /// Hex text to bytes, nil on an odd or foreign character.
    private static func bytes(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}
#endif
