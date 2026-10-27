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

    @Test("Der String-Katalog liegt in Xcodes Ordnung, sonst macht der naechste Bau den Baum schmutzig", .needsTheSources)
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

    /// The line numbers of empty lines (only whitespace). Xcode writes none,
    /// so the next build in the IDE removes a hand-left one and the tree is
    /// dirty after an archive.
    static func blankLines(_ text: String) -> [Int] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .filter { $0.element.allSatisfy(\.isWhitespace) }
            .map { $0.offset + 1 }
    }

    @Test("Die String-Kataloge haben keine leere Zeile, die der naechste Bau entfernen wuerde", .needsTheSources)
    func theCatalogsHaveNoEmptyLine() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for name in ["Localizable.xcstrings", "InfoPlist.xcstrings"] {
            let text = try String(contentsOf: root.appendingPathComponent("Sources/\(name)"), encoding: .utf8)
            #expect(text.count > 100, "the precondition: \(name) was read")
            let blank = Self.blankLines(text)
            #expect(blank.isEmpty, "\(name) has empty lines at \(blank.prefix(5))")
        }
        // The instrument: an empty line, one of spaces and one at the end
        // are caught; a catalog in Xcode's form has none.
        #expect(Self.blankLines("{\n  \"a\" : {\n\n  }\n}") == [3])
        #expect(Self.blankLines("{\n    \n}") == [2])
        #expect(Self.blankLines("{\n}\n") == [3])
        #expect(Self.blankLines("{\n  \"a\" : {\n  }\n}").isEmpty)
    }

    /// The catalog as a dictionary: key to its entry.
    static func entries() throws -> [String: [String: Any]] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/Localizable.xcstrings"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(json["strings"] as? [String: [String: Any]])
    }

    /// The keys the views look up at runtime through `LocalizedStringKey(String)`:
    /// the guide steps, notes and one-liners. Neither Xcode nor the compiler
    /// sees them, so Xcode marks them stale on every sync and a cleanup would
    /// drop their German. They are held as `manual`, which Xcode leaves alone.
    static var dynamicKeys: [String] {
        ImportGuide.allCases.flatMap { $0.steps + $0.notes }
            + [ImportGuide.pocketCastsPrivacyLine]
            + ServerGuides.localizedKeys
    }

    @Test("Der String-Katalog traegt keinen stale-Schluessel: was der Bau nicht ausgibt, ist weg (GOAL-3-4 Platz 8)", .needsTheSources)
    func theCatalogCarriesNoStaleKey() throws {
        let entries = try Self.entries()
        #expect(entries.count > 1000, "the precondition: the keys were read")
        let stale = entries.filter { ($0.value["extractionState"] as? String) == "stale" }.map(\.key).sorted()
        #expect(stale.isEmpty, "stale keys (\(stale.count)): \(stale.prefix(5))")
    }

    /// The pattern of a key as a whole string literal in Swift: each format
    /// specifier stands for an interpolation, the rest is the literal text
    /// in its escaped form.
    static func literalPattern(of key: String) throws -> String {
        let specifier = try NSRegularExpression(pattern: #"%(?:\d+\$)?(?:lld|ld|llu|lu|d|u|@|lf|\.\d+f|f)"#)
        var pieces: [String] = []
        var rest = key.startIndex
        for match in specifier.matches(in: key, range: NSRange(key.startIndex..., in: key)) {
            guard let range = Range(match.range, in: key) else { continue }
            pieces.append(String(key[rest..<range.lowerBound]))
            rest = range.upperBound
        }
        pieces.append(String(key[rest...]))
        let escaped = pieces.map {
            NSRegularExpression.escapedPattern(for: $0.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n"))
        }
        return "\"" + escaped.joined(separator: #"\\\(.*?\)"#) + "\""
    }

    /// Swift source with its `\u{…}` escapes read as the characters they are.
    static func unescaped(_ source: String) throws -> String {
        let escape = try NSRegularExpression(pattern: #"\\u\{([0-9A-Fa-f]+)\}"#)
        var text = source
        for match in escape.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let whole = Range(match.range, in: text), let hex = Range(match.range(at: 1), in: text),
                  let scalar = UInt32(text[hex], radix: 16).flatMap(Unicode.Scalar.init) else { continue }
            text.replaceSubrange(whole, with: String(Character(scalar)))
        }
        return text
    }

    /// The stale mark comes from Xcode's next sync, so a key whose code is
    /// gone sits unmarked in the catalog until someone builds in Xcode, and
    /// then that tree is dirty. Every key but the dynamic ones held manual
    /// stands as a string literal in the app or widget sources.
    @Test("Jeder Schluessel des String-Katalogs steht als Literal im Quelltext, ein toter macht den naechsten Xcode-Bau schmutzig", .needsTheSources)
    func everyCatalogKeyStandsInTheSources() throws {
        let entries = try Self.entries()
        var source = ""
        for folder in ["Sources", "LiveActivityWidget"] {
            let files = SourceTree.files(under: SourceTree.root.appendingPathComponent(folder))
                .filter { $0.pathExtension == "swift" }
            #expect(!files.isEmpty, "the fence read \(folder)")
            for file in files { source += try String(contentsOf: file, encoding: .utf8) + "\n" }
        }
        source = try Self.unescaped(source)
        let range = NSRange(source.startIndex..., in: source)
        let dead = try entries.filter { ($0.value["extractionState"] as? String) != "manual" }.map(\.key)
            .filter { try NSRegularExpression(pattern: Self.literalPattern(of: $0)).firstMatch(in: source, range: range) == nil }
            .sorted()
        #expect(dead.isEmpty, "catalog keys without their code (\(dead.count)): \(dead.prefix(5))")
        // The reader sees an interpolation, a nested call in it, an escape,
        // and a literal that only begins like the key.
        let planted = try Self.unescaped(#"""
        Text("Playing on \(device)")
        status(String(localized: "Try again in \(Duration.text(minutes: m))."))
        Text("Nothing \u{2018}hidden\u{2019}")
        """#)
        func found(_ key: String) throws -> Bool {
            try NSRegularExpression(pattern: Self.literalPattern(of: key))
                .firstMatch(in: planted, range: NSRange(planted.startIndex..., in: planted)) != nil
        }
        #expect(try found("Playing on %@"))
        #expect(try found("Try again in %@."))
        #expect(try found("Nothing \u{2018}hidden\u{2019}"))
        #expect(try !found("Playing on %@: %@"), "a longer key is not taken for a shorter literal")
    }

    /// The lines that hold a branch of a conditional with a tuple whose
    /// first element is a string literal (`? ("…", …)`, `: ("…", …)`), at
    /// the start of a line or within it. The `?` or `:` stands apart, as a
    /// conditional writes it; a label (`label: ("…")`) is no branch.
    static func literalTupleBranches(_ source: String) throws -> [String] {
        let branch = try NSRegularExpression(pattern: #"(^|\s)[?:] \(""#)
        return source.split(separator: "\n").map(String.init)
            .filter { branch.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
    }

    /// Measured on the archive of 3.5 (56): Xcode's extraction took the
    /// literal of the first branch of `isPlaylist ? ("…", false) : ("…",
    /// true)` and missed the second, which it then marked stale. Its German
    /// held only while the stale entry was built along. A wording stands in
    /// an initializer of its own, never as a tuple in a branch.
    @Test("Kein Wortlaut steht als Literal-Tupel im Zweig einer Bedingung, Xcode zieht ihn dort nicht heraus", .needsTheSources)
    func noWordingStandsInATupleBranch() throws {
        var found: [String] = []
        for folder in ["Sources", "LiveActivityWidget"] {
            let files = SourceTree.files(under: SourceTree.root.appendingPathComponent(folder))
                .filter { $0.pathExtension == "swift" }
            #expect(!files.isEmpty, "the fence read \(folder)")
            for file in files {
                found += try Self.literalTupleBranches(String(contentsOf: file, encoding: .utf8))
                    .map { "\(file.lastPathComponent): \($0.trimmingCharacters(in: .whitespaces))" }
            }
        }
        #expect(found.isEmpty, "wordings in a branch tuple (\(found.count)): \(found.prefix(5))")
        // The instrument sees both branches and leaves an initializer alone.
        #expect(try Self.literalTupleBranches("""
            isPlaylist
                ? ("This playlist has no tracks yet.", false)
                : ("The source answered without any audio track for this item.", true)
            """).count == 2)
        #expect(try Self.literalTupleBranches("""
                return (LocalizedStringResource("This playlist has no tracks yet."), false)
                let x = flag ? (count, true) : (0, false)
                show(label: ("Title", 1))
            """).isEmpty)
        // One line holds both branches: the instrument still sees them.
        #expect(try Self.literalTupleBranches("""
                let pair = isPlaylist ? ("This playlist has no tracks yet.", false) : ("No track.", true)
            """).count == 1)
    }

    @Test("Jeder dynamische Anleitungs-Schluessel steht im Katalog als manual, sonst faellt sein Deutsch beim naechsten Aufraeumen", .needsTheSources)
    func everyDynamicGuideKeyIsHeldManual() throws {
        let entries = try Self.entries()
        let keys = Set(Self.dynamicKeys)
        #expect(keys.count == 41, "the dynamic keys were read: \(keys.count)")
        let missing = keys.filter { entries[$0] == nil }.sorted()
        #expect(missing.isEmpty, "dynamic keys without a catalog entry: \(missing)")
        let unheld = keys.filter { entries[$0] != nil && (entries[$0]?["extractionState"] as? String) != "manual" }.sorted()
        #expect(unheld.isEmpty, "dynamic keys not marked manual: \(unheld)")
    }
}
#endif
