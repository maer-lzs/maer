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
}
#endif
