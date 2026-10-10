// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// In the settings every row with a symbol stands on one text edge: no row
/// indents itself by a number of its own, and no symbol is wider than the
/// column the list gives it (seen on the device at 375 pt).
struct SettingsEdgeTests {
    /// Lines that move something off the text edge but are no row indent,
    /// each with its reason. An entry whose line is gone turns the fence
    /// red, so the list only holds what still stands.
    static let notRowIndents: [String: String] = [
        "SettingsView.swift: .padding(.horizontal, 12)":
            "the inner padding of a tab choice capsule, measured to fit five text pills at 430 pt; no row",
        "SettingsView.swift: .padding(.horizontal)":
            "the strip of tab choices above the list keeps the system margin; no row",
        "PremiumFeedsSection.swift: .padding(.horizontal, 6).padding(.vertical, 2)":
            "the inner padding of the capsule that names a feed's class beside its title; no row",
        "SetupView.swift: .padding(.horizontal)":
            "the button pinned below the setup form keeps the system margin; no row",
        "RowsSettingsView.swift: .padding(.leading, row.group == nil ? 0 : groupIndent)":
            "the switches of a group of shares stand in under the group's title, decided, by a scaled value",
    ]

    /// Symbols measured wider than the list's icon column, each with its
    /// reason. None is in use today; an entry that no file uses would claim
    /// something about nothing, so the fence turns red on it.
    static let wideSymbols: [String: String] = [:]

    /// Every source of the app, comments cut, by its path below the root.
    static func sources() throws -> [String: String] {
        let folder = SourceTree.root.appendingPathComponent("Sources")
        let walker = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        var code: [String: String] = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            code[SourceTree.relativePath(of: url)] = SyncContractFenceTests.stripped(try String(contentsOf: url, encoding: .utf8))
        }
        return code
    }

    /// The settings files: the file of the settings sheet and every file
    /// whose view it builds, embedded or as a page, followed through all
    /// views they build in turn. Found from the calls, not from file names,
    /// so a section the settings embed counts whatever it is called.
    nonisolated static func reached(from root: String, in code: [String: String]) throws -> Set<String> {
        var declared: [String: Set<String>] = [:]
        let declaration = #/(?:struct|class|enum)\s+([A-Z][A-Za-z0-9_]*)[^{\n]*:[^{\n]*\bView\b/#
        for (path, text) in code {
            for match in text.matches(of: declaration) { declared[String(match.output.1), default: []].insert(path) }
        }
        let builds = try declared.map { name, paths in
            (try Regex("(?:^|[^A-Za-z0-9_.])\(name)\\s*\\(").anchorsMatchLineEndings(), paths)
        }
        var seen: Set<String> = [root]
        var todo = [root]
        while let path = todo.popLast() {
            let text = code[path] ?? ""
            for (build, paths) in builds where paths.contains(where: { !seen.contains($0) }) && text.contains(build) {
                for next in paths where seen.insert(next).inserted { todo.append(next) }
            }
        }
        return seen
    }

    /// A row's own indent: a leading or horizontal padding, with any value or
    /// none (the system margin is an indent too), alone or in a set, or an
    /// inset.
    nonisolated static func ownIndent(_ line: Substring) -> Bool {
        line.range(of: #"\.padding\(\s*(\.(leading|horizontal)\s*[,)]|\[[^\]]*\.(leading|horizontal))|EdgeInsets\("#,
                   options: .regularExpression) != nil
    }

    @Test("keine Zeile der Einstellungen rueckt sich um eine eigene Zahl ein, kein Symbol ist breiter als die Spalte", .needsTheSources)
    func everyRowStandsOnOneEdge() throws {
        let code = try Self.sources()
        let files = try Self.reached(from: "Sources/Views/SettingsView.swift", in: code)
        // The precondition names what the fence must see: the pages it opens
        // and a section it only embeds.
        #expect(["Sources/Views/RowsSettingsView.swift", "Sources/Views/SourcesSettingsView.swift",
                 "Sources/Views/Podcasts/PremiumFeedsSection.swift"].allSatisfy(files.contains),
                "the fence does not find the settings: \(files.sorted())")
        var indents: [String] = []
        var wide: [String] = []
        var used: Set<String> = []
        for name in files.sorted() {
            for line in (code[name] ?? "").split(separator: "\n") {
                let entry = "\((name as NSString).lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))"
                if Self.ownIndent(line) {
                    if Self.notRowIndents[entry] != nil { used.insert(entry) } else { indents.append(entry) }
                }
                for symbol in Self.wideSymbols.keys where line.contains("\"\(symbol)\"") {
                    wide.append("\(name): \(symbol)")
                }
            }
        }
        #expect(indents.isEmpty, "a row indents itself off the text edge: \(indents)")
        #expect(Set(Self.notRowIndents.keys).subtracting(used).isEmpty,
                "an exception whose line is gone: \(Set(Self.notRowIndents.keys).subtracting(used).sorted())")
        #expect(wide.isEmpty, "a symbol wider than the icon column: \(wide)")
        let sources = ProjectFileIntegrityTests.sourceTexts()
        let unused = Self.wideSymbols.keys.filter { symbol in !sources.contains { $0.text.contains("\"\(symbol)\"") } }
        #expect(unused.isEmpty, "a wide symbol no file uses: \(unused.sorted())")
        // Calibration: a computed indent, the system margin, a set and an
        // inset count, a vertical one does not.
        #expect(Self.ownIndent(".padding(.leading, row.group == nil ? 0 : 16)"))
        #expect(Self.ownIndent(".padding(.horizontal, inset)"))
        #expect(Self.ownIndent(".padding(.horizontal)"))
        #expect(Self.ownIndent(".padding([.leading, .top], 4)"))
        #expect(Self.ownIndent(".padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 0))"))
        #expect(!Self.ownIndent(".padding(.vertical, 4)"))
        #expect(!Self.ownIndent(".padding([.top, .bottom], 4)"))
        // Calibration of the reach: a view built by a reached view counts,
        // one nobody builds there does not, a member call is no build.
        let fake = ["A.swift": "struct A: View { var body: some View { B(x: 1); c.D() } }",
                    "B.swift": "struct B: View { let x: Int }",
                    "C.swift": "struct C: View {}", "D.swift": "struct D: View {}"]
        #expect(try Self.reached(from: "A.swift", in: fake) == ["A.swift", "B.swift"])
    }

    /// At an accessibility size the system lets a wrapped title flow under
    /// the symbol while the separator stays at the title's edge (AX3,
    /// measured); `RowLabelStyle` keeps the title's edge. The settings sheet
    /// sets it for its rows, and the two components whose label a style
    /// from outside does not reach set it on their own.
    @Test("bei Bedienungshilfen-Groessen behalten Titel ihre Kante: das Einstellungsblatt, der Schalter und die Hinweiszeile tragen den Stil", .needsTheSources)
    func titlesKeepTheirEdgeAtAccessibilitySizes() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(
                contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let library = try code("Sources/Views/LibraryView.swift")
        let sheet = try #require(library.range(of: "SettingsView(coordinator:"))
        let afterSheet = String(library[sheet.upperBound...].prefix(400))
        #expect(afterSheet.contains(".labelStyle(RowLabelStyle())"), "the settings sheet does not set the row label")
        let toggle = try #require(ABSPodcastRefreshTests.body(of: "Toggle(isOn: isOn) {", in: try code("Sources/Views/AppSwitch.swift")))
        #expect(toggle.contains(".labelStyle(RowLabelStyle())"), "the switch leaves its label to the system")
        #expect(try code("Sources/Views/HintLine.swift").contains(".labelStyle(RowLabelStyle())"), "the hint line leaves its label to the system")
    }

    /// The stacks that host a settings page outside the settings sheet, each
    /// with where. A stack inside a settings file is presented from the sheet
    /// and takes the style from there. Both ways: a host missing here, or one
    /// named here that is gone, turns the fence red.
    static let stackHosts: [String: String] = [
        "LibraryView.swift": "the settings sheet",
        "PodcastsView.swift": "the podcast sources and the access editor of a private feed, opened from the podcast tab",
        "PodcastShowView.swift": "the access editor of a private feed, opened from its show",
        "SetupView.swift": "the first screen before any server, with the map of areas and the guides",
        "ResumeMessageBanner.swift": "the notice log, opened by a tap on the hint pill",
    ]

    /// The first screens: a settings file whose own stack is a root, shown
    /// before and outside the settings sheet.
    static let firstScreens = ["SetupView.swift"]

    /// The first view a stack builds, by name; nil without one.
    nonisolated static func stackRoot(_ body: Substring) -> String? {
        guard let open = body.firstIndex(of: "{") else { return nil }
        return body[body.index(after: open)...].firstMatch(of: #/([A-Z][A-Za-z0-9_]*)\s*[({]/#).map { String($0.output.1) }
    }

    @Test("jeder Stapel ausserhalb des Einstellungsblatts, der eine Seite der Einstellungen zeigt, setzt den Zeilen-Stil", .needsTheSources)
    func everyStackOfASettingsPageSetsTheStyle() throws {
        let code = try Self.sources()
        let settings = try Self.reached(from: "Sources/Views/SettingsView.swift", in: code)
        var settingsViews: Set<String> = []
        for path in settings {
            for match in (code[path] ?? "").matches(of: #/(?:struct|class|enum)\s+([A-Z][A-Za-z0-9_]*)[^{\n]*:[^{\n]*\bView\b/#) {
                settingsViews.insert(String(match.output.1))
            }
        }
        var hosts: [String: Bool] = [:]
        for (path, text) in code where path.hasPrefix("Sources/Views/") {
            let name = (path as NSString).lastPathComponent
            let first = Self.firstScreens.contains(name)
            guard first || !settings.contains(path) else { continue }
            for range in text.ranges(of: "NavigationStack") {
                guard let body = ABSPodcastRefreshTests.body(of: "NavigationStack", in: String(text[range.lowerBound...])) else { continue }
                guard first || Self.stackRoot(Substring(body)).map(settingsViews.contains) == true else { continue }
                let after = text[range.lowerBound...].dropFirst(body.count).prefix(400)
                hosts[name] = (hosts[name] ?? true) && after.contains(".labelStyle(RowLabelStyle())")
            }
        }
        #expect(Set(hosts.keys) == Set(Self.stackHosts.keys), "the hosts of settings pages outside the sheet changed: \(hosts.keys.sorted())")
        #expect(hosts.filter { !$0.value }.isEmpty, "a stack of a settings page leaves the label to the system: \(hosts.filter { !$0.value }.keys.sorted())")
        // Calibration: the root is the first view built, not a modifier.
        #expect(Self.stackRoot("NavigationStack { PodcastSourceView() }") == "PodcastSourceView")
        #expect(Self.stackRoot("NavigationStack {\n  SettingsView(coordinator: c)\n}") == "SettingsView")
        #expect(Self.stackRoot("NavigationStack { Form { Section {} } }") == "Form")
    }
}
#endif
