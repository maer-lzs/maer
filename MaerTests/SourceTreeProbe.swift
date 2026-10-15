// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation

/// Ob die Quellen dieser Kopie ueberhaupt danebenliegen, und was daraus
/// folgt.
///
/// Die Quelltext-Zaeune lesen das Repo ueber `#filePath`. Laeuft die Suite
/// dort, wo das Repo nicht liegt, ist das eine ehrliche Enthaltung. Bisher
/// stand dafuer ein Wachposten am Anfang des Falls, und der meldete
/// BESTANDEN: *„sources unreadable, no verdict"*, und daneben ein gruenes
/// Haekchen. Ein Zaun, der seine Quellen nicht findet, sagt damit „in
/// Ordnung" genau dann, wenn er nichts weiss.
///
/// **Die zwei Faelle werden hier getrennt, und nur so wird es ehrlich:**
///
/// - **Die Quellen fehlen** ist eine Enthaltung. Das entscheidet eine
///   Bedingung VOR dem Lauf, der Fall erscheint als uebersprungen und nicht
///   als bestanden.
/// - **Die Quellen sind da und der Zaun hat trotzdem nichts gelesen** ist
///   ein BEFUND. Dann hat er seine einzige Aufgabe verfehlt, und das gehoert
///   rot.
///
/// Dieselbe Trennung wie auf der Dienst-Seite bei der Ignorier-Datei: fehlt
/// sie im Abbild, ist das in Ordnung; fehlt sie in einer Arbeitskopie, ist
/// es ein Befund. Die Frage „welcher der beiden Faelle ist es" wird gestellt,
/// statt beide gleich zu behandeln.
nonisolated enum SourceTree {
    /// Die Wurzel des Repos, aus der Lage DIESER Datei abgeleitet.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Ob der Quellordner dieser Kopie beiliegt.
    static var hasSources: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources").path)
    }

    /// Ob die Projektdatei dieser Kopie beiliegt. Eigene Frage, weil ein
    /// Lauf ohne Projektdatei die Quellen trotzdem haben kann.
    static var hasProjectFile: Bool {
        FileManager.default.fileExists(atPath:
            root.appendingPathComponent("Maer.xcodeproj/project.pbxproj").path)
    }

    /// Ob der Testordner dieser Kopie beiliegt. Der Zaun ueber den Zaeunen
    /// liest ihn, und er darf aus demselben Grund nicht still bestehen.
    static var hasTests: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("MaerTests").path)
    }

    /// Ob die Dokumente beiliegen: Inventar und Vertrag.
    static var hasDocs: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("docs").path)
    }

    /// Ob die UI-Tests beiliegen.
    static var hasUITests: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("MaerUITests").path)
    }

    /// Ob die Info.plist der App als Datei beiliegt (gebaut steckt sie im
    /// Paket, aber nicht in der Form, die die Faelle lesen).
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
    /// Der Fall liest den Quellbaum. Liegt er nicht bei, wird der Fall
    /// UEBERSPRUNGEN und nicht bestanden.
    static var needsTheSources: Self {
        .enabled(if: SourceTree.hasSources, "die Quellen liegen dieser Kopie nicht bei")
    }

    /// Der Fall liest die Projektdatei. Dasselbe eine Ebene daneben.
    static var needsTheProjectFile: Self {
        .enabled(if: SourceTree.hasProjectFile, "die Projektdatei liegt dieser Kopie nicht bei")
    }

    /// Der Fall liest den Testordner, auch seine Fixtures.
    static var needsTheTests: Self {
        .enabled(if: SourceTree.hasTests, "der Testordner liegt dieser Kopie nicht bei")
    }

    /// Der Fall liest die Dokumente.
    static var needsTheDocs: Self {
        .enabled(if: SourceTree.hasDocs, "die Dokumente liegen dieser Kopie nicht bei")
    }

    /// Der Fall liest die UI-Tests.
    static var needsTheUITests: Self {
        .enabled(if: SourceTree.hasUITests, "die UI-Tests liegen dieser Kopie nicht bei")
    }

    /// Der Fall liest die Info.plist der App als Datei.
    static var needsTheInfoPlist: Self {
        .enabled(if: SourceTree.hasInfoPlist, "die Info.plist liegt dieser Kopie nicht als Datei bei")
    }
}
#endif
