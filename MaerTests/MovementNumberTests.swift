// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The movements of a work follow by their number, read as a number:
/// after IV comes V and not IX, after 9 comes 10 and not 1 again. The
/// page and the playback ask the same order. A movement missing from the
/// recordings read ends the work instead of skipping to the one after.
struct MovementNumberTests {
    struct Recording: Equatable {
        let id: String
        let title: String
    }

    static let romans = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII"]

    /// Twelve movements in each spelling, shuffled as a source answers.
    static func work(roman: Bool) -> [Recording] {
        (1...12).map { n in
            let number = roman ? romans[n - 1] : String(n)
            return Recording(id: "mso:\(roman ? "r" : "a")\(n)", title: "Suite in D major BWV 1068 - \(number). Satz \(n)")
        }.shuffled()
    }

    static func page(_ items: [Recording]) -> [String] {
        MusopenOrder.ordered(items, title: \.title, composer: { _ in "Johann Sebastian Bach" }).map(\.id)
    }

    static func next(after id: String, in items: [Recording]) -> String? {
        MusopenOrder.nextMovement(after: id, in: items, id: \.id, title: \.title,
                                  composer: { _ in "Johann Sebastian Bach" }, performer: { _ in nil })?.id
    }

    @Test("a movement's number is read as a number, Roman and Arabic; a title without one has none")
    func theNumber() {
        #expect(MusopenOrder.movementNumber("Suite - IX. Air") == 9)
        #expect(MusopenOrder.movementNumber("Suite - XII. Gigue") == 12)
        #expect(MusopenOrder.movementNumber("Suite - IV) Bourrée") == 4)
        #expect(MusopenOrder.movementNumber("Suite - 10. Air") == 10)
        #expect(MusopenOrder.movementNumber("Wiener Blut Op. 354") == nil)
        #expect(MusopenOrder.movementNumber("Traviata - Act 1 - Libiamo") == nil)
    }

    @Test("twelve movements stand on the page in their order, in both spellings")
    func thePage() {
        #expect(Self.page(Self.work(roman: true)) == (1...12).map { "mso:r\($0)" })
        #expect(Self.page(Self.work(roman: false)) == (1...12).map { "mso:a\($0)" })
    }

    @Test("playback goes on by the number: IV to V, VIII to IX, IX to X, 9 to 10; the twelfth ends")
    func thePlayback() {
        let roman = Self.work(roman: true)
        for n in 1..<12 {
            #expect(Self.next(after: "mso:r\(n)", in: roman) == "mso:r\(n + 1)", "after \(n)")
        }
        #expect(Self.next(after: "mso:r12", in: roman) == nil)
        let arabic = Self.work(roman: false)
        for n in 1..<12 {
            #expect(Self.next(after: "mso:a\(n)", in: arabic) == "mso:a\(n + 1)", "after \(n)")
        }
        #expect(Self.next(after: "mso:a12", in: arabic) == nil)
    }

    @Test("a movement missing from the recordings read ends the work; nothing is skipped")
    func noSkip() {
        let read = Self.work(roman: true).filter { $0.id != "mso:r2" }
        #expect(Self.next(after: "mso:r1", in: read) == nil, "II was not read: III would skip it")
        #expect(Self.next(after: "mso:r3", in: read) == "mso:r4")
    }
}
#endif
