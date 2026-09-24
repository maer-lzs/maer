// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The string catalog lies in the order Xcode writes. Xcode sorts the keys
/// with the localized standard comparison whenever it syncs the catalog, so
/// a key added by hand at any other place is moved by the next build in the
/// IDE, and the tree is dirty again: the release fence then stops the
/// archive ("dirty tree"). Measured on the Xcode 27 rewrite of 25.09.2026:
/// no key and no translation changed, 23 hand-placed keys were moved and
/// three unused ones marked stale. The writer that reproduces Xcode's output
/// byte for byte sorts exactly like this.
///
/// **How to add a key by hand:** at its place in this order, or let Xcode
/// place it. `InfoPlist.xcstrings` is not held here: Xcode 27 left it
/// untouched in both measured rewrites.
struct StringCatalogOrderTests {
    /// The keys in FILE order; a decoded dictionary would lose it.
    static func keysInFileOrder(_ text: String) throws -> [String] {
        try text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("    \"") && $0.hasSuffix("\" : {") }
            .map { try JSONDecoder().decode(String.self, from: Data(String($0.dropFirst(4).dropLast(4)).utf8)) }
    }

    /// Xcode's order, pinned to the catalog's source language so the fence
    /// does not follow the simulator's locale (POSIX sorts differently).
    static func outOfOrder(_ keys: [String]) -> [String] {
        let english = Locale(identifier: "en_US")
        return zip(keys, keys.dropFirst()).compactMap { earlier, later in
            earlier.compare(later, options: [.caseInsensitive, .numeric, .widthInsensitive, .forcedOrdering],
                            locale: english) == .orderedDescending ? "\(earlier) > \(later)" : nil
        }
    }

    @Test("Der String-Katalog liegt in Xcodes Ordnung, sonst macht der naechste Bau den Baum schmutzig")
    func theCatalogIsInXcodesOrder() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/Localizable.xcstrings"), encoding: .utf8)
        let keys = try Self.keysInFileOrder(text)
        #expect(keys.count > 1000, "the precondition: the keys were read")
        let wrong = Self.outOfOrder(keys)
        #expect(wrong.isEmpty, "keys out of Xcode's order (\(wrong.count)): \(wrong.prefix(5))")
        // The instrument sees the difference, both ways: numbers compare as
        // numbers, case does not decide, and a swapped pair is caught.
        #expect(Self.outOfOrder(["Last 7 Days", "Last 14 Days"]).isEmpty)
        #expect(Self.outOfOrder(["Not Assigned", "Not in your library yet"]).isEmpty)
        #expect(Self.outOfOrder(["unexpected answer", "United Kingdom"]).isEmpty)
        #expect(Self.outOfOrder(["United Kingdom", "unexpected answer"]).count == 1)
    }
}
#endif
