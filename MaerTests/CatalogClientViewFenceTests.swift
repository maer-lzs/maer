// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// No view asks a catalogue client over the network; a loader below it
/// does, and hands back an answer. Counted per ENCLOSING TYPE, never per
/// folder: half of what first looked like calls from views sat in loader
/// enums that only live in the views folder.
struct CatalogClientViewFenceTests {
    nonisolated static let clients = ["LibriVoxClient", "ArchiveOrgClient", "GutenbergClient", "JamendoClient"]
    /// Calls that answer without the network.
    nonisolated static let offline = ["archiveBaseQuery", "clientId"]

    /// Views that still call a client, measured: none. A new one fails here.
    nonisolated static let stock: [String: Int] = [:]

    /// Client calls per view. A brace stack keeps track of the type each
    /// line sits in: a type declared and CLOSED before a call does not own
    /// it, and a call inside a helper type nested in a view is the view's.
    nonisolated static func viewCalls(in text: String) -> [String: Int] {
        var stack: [(name: String, isView: Bool, depth: Int)] = []
        var depth = 0
        var found: [String: Int] = [:]
        let declaration = #/^\s*(?:@\w+\s+)*(?:(?:private|fileprivate|public|internal|nonisolated|final)\s+)*(?:struct|enum|class|actor|extension)\s+(\w+)([^{]*)/#
        let call = #/\b(LibriVoxClient|ArchiveOrgClient|GutenbergClient|JamendoClient)\s*\.\s*(\w+)\s*\(/#
        // Comments and string contents out first, then whitespace around a
        // dot closed ACROSS lines, so a break inside a call hides nothing.
        // Braces survive the joining, so the stack below stays right.
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(IdQuestionDoorFenceTests.withoutComment($0)).replacing(#/"(?:[^"\\]|\\.)*"/#, with: "\"\"") }
            .joined(separator: "\n")
            .replacing(#/\s*\.\s*/#, with: ".")
        for line in code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let match = line.firstMatch(of: declaration) {
                let header = String(match.output.2)
                let isView = header.contains(": View") || header.contains(", View")
                    || header.contains(": ViewModifier")
                stack.append((String(match.output.1), isView, depth + 1))
            }
            for hit in line.matches(of: call) where !offline.contains(String(hit.output.2)) {
                if let owner = stack.last(where: \.isView) { found[owner.name, default: 0] += 1 }
            }
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            while let top = stack.last, depth < top.depth { stack.removeLast() }
        }
        return found
    }

    @Test("der Zaehler schreibt einen Abruf der Ansicht zu, in der er steht")
    func theCounterAttributesACallToItsView() {
        let nestedBefore = """
        struct Page: View {
            enum Answer { case a, b }
            func load() async { _ = try? await JamendoClient.popularTracks(limit: 3) }
        }
        """
        #expect(Self.viewCalls(in: nestedBefore) == ["Page": 1], "ein vorher geschlossener enum besitzt den Abruf nicht")
        let helperInside = """
        struct Page: View {
            enum Helper {
                static func f() async { _ = try? await ArchiveOrgClient.popularMusic(area: a, rows: 1, page: 1) }
            }
        }
        """
        #expect(Self.viewCalls(in: helperInside) == ["Page": 1], "ein Helfer in einer Ansicht ist Code der Ansicht")
        let loader = """
        enum Loader {
            static func f() async { _ = try? await GutenbergClient.audiobooks(languages: [], page: 1) }
        }
        struct Page: View { var body: some View { Text("x") } }
        """
        #expect(Self.viewCalls(in: loader).isEmpty, "ein Lader ist keine Ansicht, auch nicht im selben Ordner")
        #expect(Self.viewCalls(in: "struct P: View {\n let q = ArchiveOrgClient.archiveBaseQuery(for: s)\n}").isEmpty)
        #expect(Self.viewCalls(in: "struct P: View {\n // JamendoClient.popularTracks(limit: 1)\n}").isEmpty)
        #expect(Self.viewCalls(in: "struct P: View {\n func f() async { _ = try? await JamendoClient // why\n    .popularTracks(limit: 1) }\n}")
                == ["P": 1], "ein Umbruch mit Kommentar vor dem Punkt verbirgt den Abruf nicht")
    }

    @Test("Ansichten rufen keinen Katalog-Klienten, der Bestand faellt nur", .needsTheSources)
    func viewsDoNotCallCatalogClients() throws {
        let files = ProjectFileIntegrityTests.sourceFiles()
        try #require(files.count > 300, "der Zeuge hat den Quelltext nicht gelesen")
        var found: [String: Int] = [:]
        for file in files {
            found.merge(Self.viewCalls(in: try String(contentsOf: file, encoding: .utf8))) { $0 + $1 }
        }
        #expect(found == Self.stock, "Katalog-Klienten in Ansichten: \(found.sorted { $0.key < $1.key })")
    }
}
#endif
