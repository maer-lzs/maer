// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// A language whose translation waits for its review stays in the catalogs
/// but leaves a Release build: one setting of the project names it
/// (`MAER_STORE_LANGUAGES_OUT`, Release only), and the app and the widget
/// each drop its folder in a build phase of their own, before they are
/// signed. Debug builds keep every language.
struct StoreLanguagesFenceTests {
    private static func project() throws -> String {
        try SourceTree.text(SourceTree.root.appendingPathComponent("Maer.xcodeproj/project.pbxproj"))
    }

    /// The build settings of one configuration object of the project file.
    static func settings(_ project: String, id: String) -> String {
        guard let start = project.range(of: "\t\t\(id) /* ") else { return "" }
        let rest = project[start.upperBound...]
        guard let end = rest.range(of: "\n\t\t};") else { return "" }
        return String(rest[..<end.lowerBound])
    }

    @Test("the project's Release names Spanish and Italian as languages out of the store, Debug names none", .needsTheProjectFile)
    func releaseNamesTheLanguages() throws {
        let project = try Self.project()
        let release = Self.settings(project, id: "CF1170FD2FF99D9E00DA1AC5")
        let debug = Self.settings(project, id: "CF1170FC2FF99D9E00DA1AC5")
        #expect(release.contains("MAER_STORE_LANGUAGES_OUT = \"es it\";"), "the Release of the project names no languages out")
        #expect(!debug.contains("MAER_STORE_LANGUAGES_OUT"), "a Debug build leaves a language out")
        #expect(!release.isEmpty && !debug.isEmpty, "the fence read no configuration")
    }

    @Test("the app and the widget each run the one script of the store languages", .needsTheProjectFile)
    func bothTargetsRunTheScript() throws {
        let project = try Self.project()
        let call = "/bin/sh \\\"${SRCROOT}/scripts/store-languages.sh\\\""
        #expect(project.components(separatedBy: call).count - 1 == 2, "the script runs in \(project.components(separatedBy: call).count - 1) targets, not in the app and the widget")
        let script = try SourceTree.text(SourceTree.root.appendingPathComponent("scripts/store-languages.sh"))
        #expect(script.contains("[ \"${CONFIGURATION}\" = \"Release\" ] || exit 0"), "the script also acts on a Debug build")
        #expect(script.contains("en|de|fr|Base)"), "the script would drop a language the store keeps")
    }
}
#endif
