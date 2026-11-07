// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A rule in `Sources/Models` is handed what it decides on; it never asks the
/// session or the router who answers for an id. The download offer did, in a
/// `@MainActor` extension, and two of its three callers had a router of their
/// own and walked past it.
struct ModelsLayerFenceTests {
    /// The names a model may not reach: the session and its door.
    nonisolated static let upward = ["AppSession", "ItemRouter", "itemRouter"]

    /// Every upward name a text uses in code, comments at the end of a line
    /// included in the cut.
    nonisolated static func upwardNames(in text: String) -> [String] {
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(IdQuestionDoorFenceTests.withoutComment)
            .joined(separator: "\n")
        return upward.filter { code.contains($0) }
    }

    @Test("der Zaehler sieht den Namen im Code, nicht im Kommentar")
    func theCounterSeesCodeNotComments() {
        #expect(Self.upwardNames(in: "isPossible(AppSession.shared.provider(for: id).capabilities)") == ["AppSession"])
        #expect(Self.upwardNames(in: "let r = ItemRouter.live").count == 1)
        #expect(Self.upwardNames(in: "/// asks `AppSession` nowhere\nlet x = 1 // not AppSession").isEmpty)
    }

    @Test("keine Regel in Models fragt die Sitzung oder den Router", .needsTheSources)
    func noModelAsksTheSession() throws {
        let files = ProjectFileIntegrityTests.sourceFiles().filter { $0.path.contains("/Sources/Models/") }
        try #require(files.count > 50, "der Zeuge hat Models nicht gelesen")
        var found: [String] = []
        for file in files {
            let names = Self.upwardNames(in: try String(contentsOf: file, encoding: .utf8))
            found += names.map { "\(file.lastPathComponent): \($0)" }
        }
        #expect(found.isEmpty, "eine Regel in Models greift nach oben: \(found)")
    }

    // MARK: - No more upward than today

    /// The layers above the models.
    nonisolated static let upperLayers = ["Views", "ViewModels", "Providers", "Networking", "Storage"]

    /// Lines per file of `Sources/Models` that name a type declared at the
    /// top of an upper layer, measured 09.10.2026: 116 lines in 20 files.
    /// Nothing moves for it; a file may only fall, and a fall lowers its
    /// number here, so the stock never holds room for a new grip.
    /// BESTAND OHNE EINZELGRUENDE: one sentence covers every entry, each is
    /// the count of grips that stood on the day of measuring, kept as it is
    /// by decision, none chosen on its own.
    nonisolated static let upwardStock: [String: Int] = [
        "Sources/Models/AppStorageKeys.swift": 22,
        "Sources/Models/CatalogStockSurfaces.swift": 3,
        "Sources/Models/ContinueHidden.swift": 2,
        "Sources/Models/ContinueSources.swift": 1,
        "Sources/Models/DerivedStores.swift": 4,
        "Sources/Models/FreeCatalog.swift": 1,
        "Sources/Models/FreeTwin.swift": 1,
        "Sources/Models/LibraryRowDiff.swift": 1,
        "Sources/Models/ListeningStats.swift": 30,
        "Sources/Models/ListeningStatsSync.swift": 3,
        "Sources/Models/MediaDownloadOffer.swift": 1,
        "Sources/Models/PlaylistDestination.swift": 1,
        "Sources/Models/RadioGenreSources.swift": 8,
        "Sources/Models/RadioModels.swift": 6,
        "Sources/Models/RecentSearches.swift": 3,
    ]

    /// The names a text declares: at the top of the file only, or at any
    /// depth (a nested `Entry` of a model is a model's own name).
    nonisolated static func declaredNames(in text: String, topLevelOnly: Bool) -> Set<String> {
        let top = #/^(?:(?:public|private|fileprivate|internal|final|nonisolated|indirect|@\w+(?:\([^)]*\))?)\s+)*(?:struct|class|enum|protocol|actor|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)/#
        let any = #/^\s*(?:(?:public|private|fileprivate|internal|final|nonisolated|indirect|@\w+(?:\([^)]*\))?)\s+)*(?:struct|class|enum|protocol|actor|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)/#
        var names: Set<String> = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let hit = topLevelOnly ? line.firstMatch(of: top)?.output.1 : line.firstMatch(of: any)?.output.1
            if let hit { names.insert(String(hit)) }
        }
        return names
    }

    /// The lines of code: block comments, string contents and line comments
    /// cut, so a name in prose or in a log text is no grip.
    nonisolated static func codeLines(_ text: String) -> [String] {
        let blocks = text.replacing(#/\/\*[\s\S]*?\*\//#, with: "")
            .replacing(#/"""[\s\S]*?"""/#, with: "\"\"")
        return blocks.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw).replacing(#/"(?:[^"\\]|\\.)*"/#, with: "\"\"")
            guard let cut = line.range(of: "//") else { return line }
            return String(line[..<cut.lowerBound])
        }
    }

    /// How many lines of code name one of `names` as a whole word.
    nonisolated static func reachingLines(in text: String, names: Set<String>) -> Int {
        codeLines(text).filter { line in
            line.matches(of: #/[A-Za-z_][A-Za-z0-9_]*/#).contains { names.contains(String($0.output)) }
        }.count
    }

    @Test("der Zaehler der Griffe nach oben sieht Code, keinen Kommentar, keine Zeichenkette und keinen eigenen Namen")
    func theUpwardCounterSeesCodeOnly() {
        let names: Set = ["PlayerViewModel"]
        let text = """
            let a = PlayerViewModel.self
            // PlayerViewModel in a comment
            let s = "PlayerViewModel in a string"
            /* PlayerViewModel */ let b = 1
            let c = PlayerViewModelX.self
            let d = 1 // PlayerViewModel at the end
            """
        #expect(Self.reachingLines(in: text, names: names) == 1)
        let declared = "struct A {}\n    enum B {}\n@MainActor final class C {}\nnonisolated enum D {}"
        #expect(Self.declaredNames(in: declared, topLevelOnly: true) == ["A", "C", "D"])
        #expect(Self.declaredNames(in: declared, topLevelOnly: false) == ["A", "B", "C", "D"])
    }

    /// The models name the layers above them on no more lines than
    /// today, file by file, and the stock follows every fall.
    @Test("Models greift je Datei nicht oefter nach oben als heute, und der Bestand folgt jedem Fallen", .needsTheSources)
    func modelsReachUpNoMoreThanToday() throws {
        let files = ProjectFileIntegrityTests.sourceFiles()
        func layer(_ name: String) -> [URL] { files.filter { $0.path.contains("/Sources/\(name)/") } }
        var upper: Set<String> = []
        for name in Self.upperLayers {
            for file in layer(name) {
                upper.formUnion(Self.declaredNames(in: try String(contentsOf: file, encoding: .utf8), topLevelOnly: true))
            }
        }
        let models = layer("Models")
        try #require(models.count > 50 && upper.contains("PlayerViewModel") && upper.contains("MaerDatabase"),
                     "the fence did not read the layers")
        var own: Set<String> = []
        for file in models {
            own.formUnion(Self.declaredNames(in: try String(contentsOf: file, encoding: .utf8), topLevelOnly: false))
        }
        let names = upper.subtracting(own)
        var measured: [String: Int] = [:]
        for file in models {
            let count = Self.reachingLines(in: try String(contentsOf: file, encoding: .utf8), names: names)
            if count > 0 { measured[SourceTree.relativePath(of: file)] = count }
        }
        let drift = StockDrift.findings(counts: measured, stock: Self.upwardStock)
        #expect(drift.isEmpty, "a model reaches up on more lines than today, or fewer and its stock is not lowered: \(drift)")
    }
}
#endif
