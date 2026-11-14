// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A view asks „which item, which cover, which source for this id" of the
/// router in its environment (`\.itemRouter`), never of the session by name.
/// The router is the one door that translates to `AppSession`; six places
/// walked past it, and a witness could not answer for them.
///
/// Code outside a view (a free function, a factory, a background run) takes
/// the router as a parameter with the live one as default.
struct IdQuestionDoorFenceTests {
    /// The questions the router answers, in the session's own words.
    nonisolated static let questions = ["libraryItem(forId:", "coverURL(forItemId:", "provider(for:",
                                        "playableItem(forId:", "resolve(forId:"]

    /// The door itself translates to the session; that is its job.
    static let door = "ItemRouterEnvironment.swift"

    /// Names a file binds to the session itself, so `session.libraryItem`
    /// counts like `AppSession.shared.libraryItem`. A binding to a member
    /// (`let music = AppSession.shared.musicProvider`) is no alias.
    nonisolated static func aliases(in text: String) -> [String] {
        let pattern = #/\b(?:let|var)\s+(\w+)\s*(?::\s*AppSession)?\s*=\s*AppSession\.shared\b(?!\s*\.)/#
        return text.matches(of: pattern).map { String($0.output.1) }
    }

    /// A line without its comment. A `//` inside a string literal (an
    /// address) is no comment, so only one after an even number of quotes cuts.
    nonisolated static func withoutComment(_ line: Substring) -> Substring {
        var quotes = 0
        var index = line.startIndex
        while index < line.endIndex {
            if line[index] == "\"" { quotes += 1 }
            let next = line.index(after: index)
            if line[index] == "/", next < line.endIndex, line[next] == "/", quotes % 2 == 0 {
                return line[..<index]
            }
            index = next
        }
        return line
    }

    /// Every id question a text asks of the session, by name or by alias.
    /// Comments are dropped, also at the end of a line, and whitespace
    /// around a dot is closed, so a break in the middle of the expression
    /// hides nothing.
    nonisolated static func sessionQuestions(in text: String) -> [String] {
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(withoutComment)
            .joined(separator: "\n")
            .replacing(#/\s*\.\s*/#, with: ".")
        let receivers = ["AppSession.shared"] + aliases(in: code)
        var found: [String] = []
        for receiver in receivers {
            for question in questions where code.contains("\(receiver).\(question)") {
                found.append("\(receiver).\(question)")
            }
        }
        return found
    }

    @Test("the counter sees name, alias and line break, but no member as an alias")
    func theCounterSeesNameAliasAndBreak() {
        #expect(Self.sessionQuestions(in: "let x = AppSession.shared.libraryItem(forId: id)").count == 1)
        #expect(Self.sessionQuestions(in: "let s = AppSession.shared\nlet x = s.coverURL(forItemId: id)").count == 1)
        #expect(Self.sessionQuestions(in: "@ObservedObject private var session = AppSession.shared\n"
                                          + "session.provider(for: id)").count == 1)
        #expect(Self.sessionQuestions(in: "AppSession.shared\n    .resolve(forId: id, carried: nil)").count == 1)
        #expect(Self.sessionQuestions(in: "let music = AppSession.shared.musicProvider\n"
                                          + "music.libraryItem(forId: id)").isEmpty,
                "ein Glied der Sitzung ist kein Alias der Sitzung")
        #expect(Self.sessionQuestions(in: "// AppSession.shared.libraryItem(forId: id)").isEmpty)
        #expect(Self.sessionQuestions(in: "AppSession.shared // why\n    .coverURL(forItemId: id)").count == 1,
                "ein Kommentar am Zeilenende verbirgt den Umbruch nicht")
        #expect(Self.sessionQuestions(in: "let u = \"https://x\"; AppSession.shared.provider(for: id)").count == 1,
                "eine Adresse im Text ist kein Kommentar")
    }

    @Test("no view asks the session by name for the title, cover or source of an id",
          .needsTheSources)
    func noViewAsksTheSessionForAnId() throws {
        let files = ProjectFileIntegrityTests.sourceFiles().filter { $0.path.contains("/Sources/Views/") }
        try #require(files.count > 100, "der Zeuge hat den Ansichtsbaum nicht gelesen")
        var callers: [String] = []
        var doorAsks = 0
        for file in files {
            let found = Self.sessionQuestions(in: try String(contentsOf: file, encoding: .utf8))
            if file.lastPathComponent == Self.door { doorAsks = found.count; continue }
            callers += found.map { "\(file.lastPathComponent): \($0)" }
        }
        #expect(callers.isEmpty, "eine Ansicht geht am Router vorbei: \(callers)")
        #expect(doorAsks == Self.questions.count, "die Tuer selbst beantwortet jede Frage aus der Sitzung")
    }
}
#endif
