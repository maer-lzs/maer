// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation

/// Whether the sources of this copy lie beside it at all, and what follows.
///
/// The source fences read the repository through `#filePath`. A suite that
/// runs where the repository is not abstains, honestly. A guard at the start
/// of a case would report PASSED there, and a fence that cannot find its
/// sources would say "fine" exactly when it knows nothing.
///
/// **The two cases are kept apart here, and only that makes it honest:**
///
/// - **The sources are missing** is an abstention. A condition BEFORE the
///   run decides it, and the case shows as skipped, not as passed.
/// - **The sources are there and the fence read nothing anyway** is a
///   FINDING. The fence missed its one task, and that is red.
///
/// The same split as on the service side for the ignore file: missing in
/// the image is fine, missing in a working copy is a finding. The question
/// which of the two cases it is gets asked instead of treating both alike.
nonisolated enum SourceTree {
    /// The root of the repository, derived from where THIS file lies.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Whether the source folder lies with this copy.
    static var hasSources: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources").path)
    }

    /// Whether the project file lies with this copy. A question of its own,
    /// because a run without the project file can still have the sources.
    static var hasProjectFile: Bool {
        FileManager.default.fileExists(atPath:
            root.appendingPathComponent("Maer.xcodeproj/project.pbxproj").path)
    }

    /// Whether the test folder lies with this copy. The fence over the
    /// fences reads it, and for the same reason it must not pass silently.
    static var hasTests: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("MaerTests").path)
    }

    /// Whether the documents lie with this copy: inventory and contract.
    static var hasDocs: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("docs").path)
    }

    /// Whether the UI tests lie with this copy.
    static var hasUITests: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("MaerUITests").path)
    }

    /// Whether the pages of the website lie with this copy (`site`).
    static var hasSite: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("site").path)
    }

    /// Whether the app's Info.plist lies with this copy as a file (built, it
    /// is inside the bundle, but not in the form the cases read).
    static var hasInfoPlist: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("Maer-Info.plist").path)
    }

    /// The path below the repository root, built from the path COMPONENTS
    /// after both sides are resolved. The one way the tests name a walked
    /// file; `RelativePathFenceTests` holds that no test cuts a path by text.
    ///
    /// **Measured at another machine's gate, not here:** the first version
    /// cut the root off with a string replacement. In a worktree under
    /// `/private/tmp` the file's own path carries the resolved `/private`
    /// while the root from `#filePath` carries the symlink form, so the
    /// replacement matched in the MIDDLE and produced `/privatedocs/EULA.md`.
    /// A name nobody has means the licence exception does not match it, and
    /// the fence then reports the one name that has to stand there. The fence
    /// was green in the tree it was written in and red where releases are
    /// measured.
    static func relativePath(of url: URL) -> String {
        let root = Self.root.resolvingSymlinksInPath().pathComponents
        let file = url.resolvingSymlinksInPath().pathComponents
        guard file.count > root.count, Array(file.prefix(root.count)) == root else {
            // Not below the root: say the whole path rather than a plausible
            // fragment, because a wrong name is worse than a long one.
            return url.path
        }
        return file.dropFirst(root.count).joined(separator: "/")
    }

    /// Every file below `folder`, recursively: the one way a test walks
    /// the tree. A walk that finds nothing records an issue at the caller,
    /// so a fence over a missing folder is red, never a pass over nothing;
    /// only the condition in the case's head (`.needsTheSources` and its
    /// neighbours) turns that into a skip.
    static func files(under folder: URL, sourceLocation: SourceLocation = #_sourceLocation) -> [URL] {
        let found = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        if found.isEmpty {
            Issue.record("no file below \(relativePath(of: folder)): the walk read nothing", sourceLocation: sourceLocation)
        }
        return found
    }
}

/// The one walk is loud: over nothing it records its issue, over files it
/// says nothing and returns each. Neither of these two reads the tree, so
/// neither carries a condition; the count of walks reads the tests.
struct SourceTreeWalkTests {
    @Test("ein Lauf ueber einen Ordner, den es nicht gibt, meldet ein Issue")
    func aWalkOverNothingSaysSo() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-tree-\(UUID().uuidString)")
        withKnownIssue("the walk over a missing folder records its issue") {
            #expect(SourceTree.files(under: missing).isEmpty)
        }
    }

    @Test("ein Lauf ueber Dateien meldet nichts und liefert jede, auch in Unterordnern")
    func aWalkOverFilesFindsEach() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tree-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appendingPathComponent("a.swift"))
        try Data("b".utf8).write(to: folder.appendingPathComponent("inner/b.swift"))
        #expect(SourceTree.files(under: folder).map(\.lastPathComponent).sorted() == ["a.swift", "b.swift"])
    }

    /// The run without the tree sees a case that reads the tree only when
    /// the read fails loudly. A new walk of its own that comes back empty
    /// without a word would pass there, so the test tree walks through
    /// `files(under:)` alone. Each other walk is counted, with why.
    static let ownWalks: [String: (count: Int, reason: String)] = [
        "SourceTreeProbe.swift": (1, "the one walk itself"),
        "FeedAuthOwnerTests.swift": (1, "the folder of a test rig, not the tree"),
    ]

    @Test("kein Test laeuft selbst ueber einen Ordner, ausser dem einen Lauf und dem Ordner eines Pruefstands", .needsTheTests)
    func everyWalkGoesThroughTheOne() {
        // Built from two parts, so this file does not count its own search.
        let token = "FileManager.default." + "enumerator("
        var counts: [String: Int] = [:]
        for url in SourceTree.files(under: SourceTree.root.appendingPathComponent("MaerTests")) where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                Issue.record("unreadable: \(SourceTree.relativePath(of: url))")
                continue
            }
            let hits = text.split(separator: "\n").filter {
                !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && $0.contains(token)
            }.count
            if hits > 0 { counts[url.lastPathComponent] = hits }
        }
        #expect(StockDrift.findings(counts: counts, stock: Self.ownWalks.mapValues(\.count)) == [],
                "a walk past files(under:), or a stock above the count")
        #expect(Self.ownWalks.values.allSatisfy { !$0.reason.isEmpty })
    }
}

extension Trait where Self == ConditionTrait {
    /// The case reads the source tree. Without it, the case is SKIPPED, not
    /// passed.
    static var needsTheSources: Self {
        .enabled(if: SourceTree.hasSources, "die Quellen liegen dieser Kopie nicht bei")
    }

    /// The case reads the project file. The same, one level beside.
    static var needsTheProjectFile: Self {
        .enabled(if: SourceTree.hasProjectFile, "die Projektdatei liegt dieser Kopie nicht bei")
    }

    /// The case reads the test folder, its fixtures too.
    static var needsTheTests: Self {
        .enabled(if: SourceTree.hasTests, "der Testordner liegt dieser Kopie nicht bei")
    }

    /// The case reads the documents.
    static var needsTheDocs: Self {
        .enabled(if: SourceTree.hasDocs, "die Dokumente liegen dieser Kopie nicht bei")
    }

    /// The case reads the UI tests.
    static var needsTheUITests: Self {
        .enabled(if: SourceTree.hasUITests, "die UI-Tests liegen dieser Kopie nicht bei")
    }

    /// The case reads the app's Info.plist as a file.
    static var needsTheInfoPlist: Self {
        .enabled(if: SourceTree.hasInfoPlist, "die Info.plist liegt dieser Kopie nicht als Datei bei")
    }

    /// The case reads the pages of the website.
    static var needsTheSite: Self {
        .enabled(if: SourceTree.hasSite, "die Seiten der Website liegen dieser Kopie nicht bei")
    }
}
#endif
