// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The next-steps card's Audiobookshelf row: a signed-in person lands on
/// the source page in BOTH hosts, never on the empty login form. The
/// first-start sheet used to hand out the form unconditionally while the
/// settings host branched right; the rule is one, and both hosts read it.
struct NextStepsRulesTests {
    @Test("a session leads to the source page, none to the form")
    func theRule() {
        #expect(NextStepsRules.absDestination(isLoggedIn: true) == .sourcePage)
        #expect(NextStepsRules.absDestination(isLoggedIn: false) == .loginForm)
    }

    /// Both hosts: the sheet maps the rule onto the two pages, the settings
    /// host hands out the source page (which carries the form behind its
    /// connect button). Whitespace is pulled together so the call may break
    /// over lines; comment lines do not count.
    @Test("both hosts follow the rule: the sheet through it, the settings through the source page", .needsTheSources)
    func bothHostsFollowTheRule() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func code(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
                .components(separatedBy: .whitespacesAndNewlines).joined()
        }
        let sheet = try code("Sources/Views/NextStepsView.swift")
        let sheetStart = try #require(sheet.range(of: "structNextStepsSheet"))
        let sheetBody = sheet[sheetStart.upperBound...]
        #expect(sheetBody.contains("NextStepsRules.absDestination(isLoggedIn:"), "the sheet does not ask the rule")
        #expect(sheetBody.contains("case.sourcePage:returnAnyView(ABSSourceView("), "the sheet's signed-in branch is not the source page")
        #expect(sheetBody.contains("case.loginForm:returnAnyView(ABSLoginPage("), "the sheet's signed-out branch is not the form")
        let settings = try code("Sources/Views/SettingsView.swift")
        let page = try #require(settings.range(of: "privatefuncabsPage()->AnyView{"))
        let pageBody = settings[page.upperBound...].prefix(120)
        #expect(pageBody.contains("AnyView(ABSSourceView("), "the settings host must hand out the source page")
    }
}
#endif
