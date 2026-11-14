// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The recovery key of the travelling feed accesses: its
/// WRITTEN FORM (pure) and the one promise the whole point hangs on,
/// namely that it does not travel through Apple.
struct DeviceLinkCodeTests {

    // MARK: - The written form

    /// A code the tests write by hand. Only letters from the
    /// alphabet, exactly as long as asked.
    static let sample = "ABCDEFGHJKMNPQRSTVWXYZAB"
    static let other  = "ZYXWVTSRQPNMKJHGFEDCBAZY"

    @Test("twenty-four characters become six groups, everything else stays as it is")
    func groupingIsSixBlocksOrNothing() {
        let code = Self.sample
        #expect(code.count == DeviceLinkCode.length)
        #expect(DeviceLinkCode.grouped(code) == "ABCD-EFGH-JKMN-PQRS-TVWX-YZAB")
        // A wrong length gets NO familiar shape: otherwise
        // a broken value looks like a correct one.
        #expect(DeviceLinkCode.grouped("ABCD") == "ABCD")
        #expect(DeviceLinkCode.grouped("") == "")
    }

    @Test("what a person types is read: dashes, spaces, lowercase")
    func readingAcceptsWhatPeopleType() {
        let want = Self.sample
        #expect(DeviceLinkCode.normalized("ABCD-EFGH-JKMN-PQRS-TVWX-YZAB") == want)
        #expect(DeviceLinkCode.normalized("abcd efgh jkmn pqrs tvwx yzab") == want)
        #expect(DeviceLinkCode.normalized("abcdefghjkmnpqrstvwxyzab") == want)
    }

    @Test("the confusable characters do not exist in the first place, and nothing is silently corrected")
    func theConfusableShapesSimplyDoNotOccur() {
        // Without digits in the alphabet the mix-up cannot arise:
        // nobody sees a 1 here and types an I for it. So nothing is
        // mapped either, it is rejected, and the rejection tells the
        // person where they looked.
        for confusable: Character in ["I", "L", "O", "U"] {
            #expect(!DeviceLinkCode.alphabet.contains(confusable),
                    "\(confusable) darf im Alphabet nicht vorkommen")
        }
        #expect(DeviceLinkCode.normalized("IBCDEFGHJKMNPQRSTVWXYZAB") == nil)
        #expect(DeviceLinkCode.normalized("1BCDEFGHJKMNPQRSTVWXYZAB") == nil, "keine Ziffern")
        #expect(DeviceLinkCode.alphabet.allSatisfy { $0.isLetter }, "nur Buchstaben")
        #expect(DeviceLinkCode.alphabet.count == 22)
    }

    @Test("too short, too long or a foreign character is NO code")
    func anythingElseIsNotACode() {
        #expect(DeviceLinkCode.normalized(String(Self.sample.dropLast())) == nil, "eins zu kurz")
        #expect(DeviceLinkCode.normalized(Self.sample + "C") == nil, "eins zu lang")
        #expect(DeviceLinkCode.normalized("ABCDEFGHJKMNPQRSTVWXY!B") == nil, "fremdes Zeichen")
        #expect(DeviceLinkCode.normalized("") == nil)
        // A code that is too short must not be passed on: the
        // decryption could afterwards only say "falscher Schluessel",
        // and the person looks for the error in the wrong place.
        #expect(!DeviceLinkCode.isCode(String(Self.sample.dropLast())))
    }

    // MARK: - The generation

    @Test("skewing bytes are DISCARDED, measured against the FUNCTION")
    func biasingBytesAreRejected() throws {
        // 22 does not divide 256. Whoever computes `byte % 22` makes the first
        // fourteen letters more frequent than the other eight.
        let alphabet = DeviceLinkCode.alphabet
        let ceiling = 256 - (256 % alphabet.count)
        #expect(ceiling == 242, "22 mal 11, die groesste ganze Vielfache unter 256")

        // Exhaustive over ALL 256 byte values, and THROUGH the
        // function instead of through a replica of its arithmetic. A
        // witness that forms `alphabet[byte % 22]` itself measures the
        // assumption; this one measures what the code does, and therefore also sees
        // a shifted rejection boundary.
        let filler = [UInt8](repeating: 0, count: DeviceLinkCode.length)
        for value in 0..<256 {
            let byte = UInt8(value)
            let code = try #require(DeviceLinkCode.code(fromRandomBytes: [byte] + filler))
            if value < ceiling {
                #expect(code.first == alphabet[value % alphabet.count],
                        "Byte \(value) muss den Buchstaben \(value % alphabet.count) geben")
            } else {
                // Discarded: the first character comes from the next byte.
                #expect(code.first == alphabet[0],
                        "Byte \(value) haette verworfen werden muessen")
            }
        }

        // And every letter is reachable through the function, none
        // falls out of the alphabet.
        var reachable: Set<Character> = []
        for value in 0..<ceiling {
            let code = try #require(DeviceLinkCode.code(fromRandomBytes: [UInt8(value)] + filler))
            reachable.insert(try #require(code.first))
        }
        #expect(reachable.count == alphabet.count, "erreichbar: \(reachable.count)")
    }

    @Test("too little randomness gives NO code")
    func tooLittleRandomnessGivesNothing() {
        #expect(DeviceLinkCode.code(fromRandomBytes: []) == nil)
        #expect(DeviceLinkCode.code(fromRandomBytes: [1, 2, 3]) == nil)
        // Nothing but skewing bytes is as good as none.
        #expect(DeviceLinkCode.code(fromRandomBytes: [UInt8](repeating: 255, count: 200)) == nil)
    }

    @Test("the strength stands as a number, not as a claim")
    func theStrengthIsANumber() {
        // 100 bits. Whoever shortens the alphabet or the code to make
        // the input more convenient fails here and reads the reason: a
        // short code would be searchable offline by whoever
        // holds the block anyway.
        // 107 bits. Whoever shortens the alphabet or the code to make
        // the input more convenient fails here. And the input does not
        // become more convenient: measured, the mixed form with 20
        // characters costs 28.5 keystrokes, this one with 24 only 24.
        #expect(DeviceLinkCode.entropyBits == 107)
        #expect(DeviceLinkCode.length == 24)
        #expect(DeviceLinkCode.entropyBits >= 100, "unter 100 Bit wird der Code durchsuchbar")
    }

    @Test("Round trip: generated, grouped, read again, the same code")
    func roundTrip() throws {
        let bytes: [UInt8] = [21, 0, 17, 9, 4, 19, 20, 1, 12, 8, 3, 15,
                              11, 6, 18, 2, 13, 5, 10, 7, 16, 14, 9, 3]
        let code = try #require(DeviceLinkCode.code(fromRandomBytes: bytes))
        let written = DeviceLinkCode.grouped(code)
        #expect(written.contains("-"))
        #expect(DeviceLinkCode.normalized(written) == code)
        #expect(DeviceLinkCode.isCode(code))
    }

    // MARK: - The promise the point hangs on

    /// A source-text fence, and here it is the only honest safeguard:
    /// whether a key lands in Apple's iCloud keychain, a
    /// behavior case in the simulator does not see. The same construction as for the
    /// time comparison, which cannot tell `==` and `compare_digest` apart.
    @Test("the recovery key NEVER travels through Apple", .needsTheSources)
    func theRecoveryKeyNeverTravelsThroughApple() throws {
        let door = try #require(ProjectFileIntegrityTests.sourceFiles()
            .first { $0.lastPathComponent == "DeviceLinkCodeStore.swift" })
        let text = try String(contentsOf: door, encoding: .utf8)
        // The door writes with the default, so device-local. It
        // passes the travel parameter nowhere, not even with false:
        // if it stood there, it would be an adjusting screw, and an adjusting screw
        // at this place is the gap itself.
        #expect(!text.contains("synchronizable"),
                "die Schluessel-Tuer nennt den Reise-Parameter")
        // Since S3 no code is generated any more: the door reads and forgets,
        // it cannot write.
        #expect(!text.contains("KeychainStore.save("), "die Tuer schreibt noch einen Code")
        #expect(text.contains("KeychainStore.load(") && text.contains("KeychainStore.delete("))

        // And the name of the key lives only in this one place, so that
        // nobody writes it elsewhere with other conditions.
        var holders: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let body = try String(contentsOf: file, encoding: .utf8)
            if body.contains("deviceLinkCode") { holders.append(file.lastPathComponent) }
        }
        #expect(holders == ["DeviceLinkCodeStore.swift"], "Halter: \(holders.sorted())")
    }
}
#endif
