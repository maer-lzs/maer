// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A test names a walked file by `SourceTree.relativePath(of:)`, never by
/// cutting the root off its path as text. The file walker hands out
/// /private/tmp where the root says /tmp; a text cut then keeps the whole
/// path, and a half-resolved cut (one side resolved, the other not) breaks
/// the same way. Resolving does not make a text cut safe, so the fence asks
/// for no text cut at all.
struct RelativePathFenceTests {
    /// Text cuts of a path prefix: `<x>.path.replacingOccurrences(of:` whose
    /// `of:` argument is itself a path, also when the call wraps lines.
    static func textCuts(in code: String) -> [String] {
        let pattern = #"\.path\s*\.replacingOccurrences\(\s*of:(?:(?!with:)[\s\S])*?\.path"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return ["the fence's pattern does not compile"] }
        let whole = NSRange(code.startIndex..., in: code)
        return regex.matches(in: code, range: whole).compactMap { match in
            Range(match.range, in: code).map { String(code[$0]).split(separator: "\n").joined(separator: " ") }
        }
    }

    @Test("ein Test nennt einen gewanderten Pfad nur ueber SourceTree.relativePath", .needsTheTests)
    func walkedPathsAreNamedByComponents() throws {
        var offenders: [String] = []
        var read = 0
        for folder in ["MaerTests", "MaerUITests"] {
            for url in SourceTree.files(under: SourceTree.root.appendingPathComponent(folder)) where url.pathExtension == "swift"
                && url.lastPathComponent != "RelativePathFenceTests.swift" {
                read += 1
                let code = SyncContractFenceTests.stripped(try String(contentsOf: url, encoding: .utf8))
                offenders += Self.textCuts(in: code).map { "\(url.lastPathComponent): \($0)" }
            }
        }
        #expect(read > 100, "the fence read only \(read) test files")
        #expect(offenders.isEmpty, "a path cut by text instead of SourceTree.relativePath: \(offenders)")
    }

    /// Every form the earlier fence let through is caught now, and a text
    /// replacement that is no path cut is not.
    @Test("der Zaun faengt jede Schnittform, auch halb aufgeloest und umgebrochen")
    func everyCutFormIsCaught() {
        let forms = [
            #"let p = url.path.replacingOccurrences(of: root.path + "/", with: "")"#,
            #"let p = url.resolvingSymlinksInPath().path.replacingOccurrences(of: root.resolvingSymlinksInPath().path + "/", with: "")"#,
            #"let p = url.resolvingSymlinksInPath().path.replacingOccurrences(of: root.path + "/", with: "")"#,
            #"let p = url.path.replacingOccurrences(of: root.resolvingSymlinksInPath().path + "/", with: "")"#,
            "let p = url.path.replacingOccurrences(\n    of: root.path + \"/\", with: \"\")",
            #"let p = url.path.replacingOccurrences(of: root.path, with: "")"#,
        ]
        for form in forms {
            #expect(Self.textCuts(in: form).count == 1, "a cut form went through: \(form)")
        }
        #expect(Self.textCuts(in: #"let safe = name.replacingOccurrences(of: "/", with: "_")"#).isEmpty)
        #expect(Self.textCuts(in: #"let p = SourceTree.relativePath(of: url)"#).isEmpty)
    }
}
#endif
