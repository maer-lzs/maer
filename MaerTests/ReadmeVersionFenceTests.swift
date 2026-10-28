// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation

/// What the READMEs and the changelog say about versions is read from the
/// project, not trusted: the minimum system the READMEs name is the
/// deployment target, and every app version they name, in the form the
/// changelog writes (`v3.4 (Build 51)`), is the stamp of the project. The
/// changelog's newest heading is that stamp too. Both READMEs carry the same
/// headings and the same code blocks, so the German one cannot fall behind
/// the English one by a section again.
///
/// What cannot be read from the project (features, the servers that work)
/// stays the review by hand at every stamp.
struct ReadmeVersionFenceTests {

    static let readmes = ["README.md", "README.de.md"]

    static func text(_ relative: String) throws -> String {
        try String(contentsOf: SourceTree.root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Every value one build setting has in the project file, as written.
    static func settingValues(_ name: String, in project: String) -> Set<String> {
        var values: Set<String> = []
        for line in project.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(name + " = "), trimmed.hasSuffix(";") else { continue }
            let value = trimmed.dropFirst(name.count + 3).dropLast()
            values.insert(String(value).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        }
        return values
    }

    /// The minimum system a README names: the bold `iOS/iPadOS <version>`
    /// that stands in its requirements, in either language.
    static func minimumVersions(in text: String) -> [String] {
        text.matches(of: #/\*\*iOS/iPadOS (\d+(?:\.\d+)*)\*\*/#).map { String($0.output.1) }
    }

    /// Every app version named with its build, `v3.4 (Build 51)` or
    /// `3.4 (Build 51)`, as version and build.
    static func namedStamps(in text: String) -> [(version: String, build: String)] {
        text.matches(of: #/v?(\d+\.\d+(?:\.\d+)?) \(Build (\d+)\)/#).map {
            (String($0.output.1), String($0.output.2))
        }
    }

    /// The newest stamp the changelog names: what its first `## v` heading
    /// says, nil when that heading carries no `(Build …)`. Entries above it
    /// belong to the next build, not yet cut. Only the first heading counts:
    /// a new one without its build may not hand the question to an older one.
    static func newestChangelogStamp(in text: String) -> (version: String, build: String)? {
        guard let newest = text.split(separator: "\n").first(where: { $0.hasPrefix("## v") }) else { return nil }
        return namedStamps(in: String(newest)).first
    }

    /// The headings of a README (`#` to `###`) and its code fences, counted.
    static func outline(of text: String) -> (headings: [Int], fences: Int) {
        var headings: [Int] = []
        var fences = 0
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                fences += 1
                inFence.toggle()
                continue
            }
            guard !inFence, line.hasPrefix("#") else { continue }
            let level = line.prefix { $0 == "#" }.count
            if level <= 3, line.dropFirst(level).hasPrefix(" ") { headings.append(level) }
        }
        return (headings, fences)
    }

    @Test("die Mindestversion beider READMEs ist das Deployment-Ziel des Projekts", .needsTheSources, .needsTheProjectFile)
    func theReadmesNameTheDeploymentTarget() throws {
        let project = try Self.text("Maer.xcodeproj/project.pbxproj")
        let targets = Self.settingValues("IPHONEOS_DEPLOYMENT_TARGET", in: project)
        try #require(targets.count == 1, "one deployment target in the project: \(targets.sorted())")
        let target = try #require(targets.first)
        for name in Self.readmes {
            let named = Self.minimumVersions(in: try Self.text(name))
            let wrong = named.filter { $0 != target }
            #expect(!named.isEmpty, "\(name) names no minimum system")
            #expect(wrong.isEmpty, "\(name) names \(named), the project says \(target)")
        }
    }

    @Test("jede genannte App-Version ist der Stempel des Projekts, im Changelog die neueste Ueberschrift auch", .needsTheSources, .needsTheProjectFile)
    func everyNamedVersionIsTheStamp() throws {
        let project = try Self.text("Maer.xcodeproj/project.pbxproj")
        let versions = Self.settingValues("MARKETING_VERSION", in: project)
        let builds = Self.settingValues("CURRENT_PROJECT_VERSION", in: project)
        try #require(versions.count == 1 && builds.count == 1,
                     "one stamp in the project: \(versions.sorted()) \(builds.sorted())")
        let version = try #require(versions.first)
        let build = try #require(builds.first)
        let changelog = try Self.text("CHANGELOG.md")
        let newest = try #require(Self.newestChangelogStamp(in: changelog),
                                  "the changelog's first version heading names no build")
        #expect(newest.version == version && newest.build == build,
                "the changelog's newest stamp is \(newest.version) (Build \(newest.build)), the project says \(version) (Build \(build))")
        // Today neither README names a version as `X.Y (Build N)`, so this
        // half finds nothing to check; it holds a stamp written that way
        // later to the project's. The screenshot section names its build in
        // the short form `3.5 (56)` on purpose: it says which build the
        // pictures show, not the current stamp, and this reader leaves the
        // short form alone.
        for name in Self.readmes {
            let wrong = Self.namedStamps(in: try Self.text(name))
                .filter { $0.version != version || $0.build != build }
                .map { "\($0.version) (Build \($0.build))" }
            #expect(wrong.isEmpty, "\(name) names \(wrong), the project says \(version) (Build \(build))")
        }
    }

    /// What this measures is the outline, not the wording: the sequence of
    /// heading levels and the number of code fences, the same in both
    /// languages. A heading translated wrongly passes; a section missing in
    /// one README does not. An odd number of fence markers is an unclosed
    /// code block.
    @Test("beide READMEs tragen dieselbe Gliederung: Ebenenfolge der Ueberschriften und Zahl der Code-Bloecke", .needsTheSources)
    func bothReadmesHaveTheSameOutline() throws {
        let english = Self.outline(of: try Self.text("README.md"))
        let german = Self.outline(of: try Self.text("README.de.md"))
        #expect(english.headings.count > 10, "the outline reader found no sections")
        #expect(english.headings == german.headings, "heading levels: \(english.headings) against \(german.headings)")
        #expect(english.fences == german.fences, "code fences: \(english.fences) against \(german.fences)")
        #expect(english.fences % 2 == 0 && german.fences % 2 == 0,
                "a code block is not closed: \(english.fences) and \(german.fences) fence markers")
    }

    /// The readers on planted text: each would see the drift it guards.
    @Test("die Leser sehen eine falsche Mindestversion, einen fremden Stempel und eine fehlende Ueberschrift")
    func theReadersSeeTheDrift() throws {
        #expect(Self.minimumVersions(in: "- Deployment target **iOS/iPadOS 26.5** (minimum)") == ["26.5"])
        #expect(Self.minimumVersions(in: "- Deployment-Ziel **iOS/iPadOS 18.0** (Mindest)") == ["18.0"])
        #expect(Self.minimumVersions(in: "uses Liquid Glass on iOS 26 and later").isEmpty)
        #expect(Self.settingValues("MARKETING_VERSION", in: "\t\t\t\tMARKETING_VERSION = 3.4;\n\t\t\t\tMARKETING_VERSION = 3.3;")
                == ["3.4", "3.3"])
        #expect(Self.settingValues("IPHONEOS_DEPLOYMENT_TARGET", in: "IPHONEOS_DEPLOYMENT_TARGET = 18.0;") == ["18.0"])
        let named = Self.namedStamps(in: "Mär v3.3 (Build 50) and 3.4 (Build 51); Version 2.0 added podcasts")
        #expect(named.map(\.version) == ["3.3", "3.4"] && named.map(\.build) == ["50", "51"])
        let changelog = "# Changelog\n\n## Next build (not yet cut)\n\n**New.**\n\n## v3.4 (Build 51)\n\n## v3.3 (Build 50)\n"
        let newest = try #require(Self.newestChangelogStamp(in: changelog))
        #expect(newest.version == "3.4" && newest.build == "51")
        // A new heading without its build is a finding, not a pass to the
        // older heading below it.
        let unstamped = "# Changelog\n\n## v3.5\n\n## v3.4 (Build 51)\n"
        let handedOn = Self.newestChangelogStamp(in: unstamped)?.version
        #expect(handedOn == nil, "an unstamped heading handed the question on to \(handedOn ?? "-")")
        let full = Self.outline(of: "# A\n## B\n```text\n# not a heading\n```\n### C\n")
        let missing = Self.outline(of: "# A\n### C\n")
        #expect(full.headings == [1, 2, 3] && full.fences == 2)
        #expect(full.headings != missing.headings)
        #expect(Self.outline(of: "# A\n```text\nopen\n## B\n").fences % 2 == 1, "the reader sees an unclosed block")
    }
}
#endif
