// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The local library asks ONE root where an entry's files live and what
/// removing it does. The container is the default and behaves as before; a
/// stand-in root proves every read and every removal goes through it.
@MainActor
struct LocalFileRootTests {
    /// A root that keeps every entry in a folder of its own and only notes a
    /// removal, the way a linked folder will (its files stay where they are).
    final class StandIn: LocalFileRoot {
        let base: URL
        private(set) var removed: [String] = []
        init(base: URL) { self.base = base }
        func folder(forEntry id: String) -> URL? {
            base.appendingPathComponent(String(id.dropFirst("local:".count)), isDirectory: true)
        }
        func removeFiles(ofEntry id: String) { removed.append(id) }
    }

    private struct Home {
        let directory: URL
        var audioDir: URL { directory.appendingPathComponent("LocalAudio", isDirectory: true) }
        var elsewhere: URL { directory.appendingPathComponent("Elsewhere", isDirectory: true) }
        func library(root: (any LocalFileRoot)? = nil) -> LocalLibrary {
            LocalLibrary(database: MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path),
                         audioDir: audioDir, root: root)
        }
        /// One entry "local:book" with one track and a cover, seeded into
        /// the rows.
        func seed() async throws {
            let entry = LocalLibrary.Entry(id: "local:book", title: "Book", author: nil, duration: 1, addedAt: 1,
                                           trackFiles: ["a.m4a"], chapters: [], hasCover: true)
            let database = MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path)
            let rows = try await KeyedRowStore<LocalLibrary.Entry>(connection: try database.connection(), table: .localLibrary)
            _ = try await rows.replaceAll([entry.id: entry])
        }
        func put(_ name: String, in folder: URL) throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
    }

    private func home() throws -> Home {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("localroot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Home(directory: directory)
    }

    @Test("without an own root everything lies in the container, as before")
    func theContainerBehavesAsBefore() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        try await home.seed()
        let folder = home.audioDir.appendingPathComponent("book", isDirectory: true)
        try home.put("a.m4a", in: folder)
        try home.put("cover.jpg", in: folder)
        let library = home.library()
        #expect(library.fileURL(forContentPath: "book/a.m4a")?.standardizedFileURL
                == folder.appendingPathComponent("a.m4a").standardizedFileURL)
        #expect(library.coverURL(forItemId: "local:book")?.standardizedFileURL
                == folder.appendingPathComponent("cover.jpg").standardizedFileURL)
        #expect(library.fileURL(forContentPath: "book/missing.m4a") == nil, "a missing file is no address")
        #expect(library.fileURL(forContentPath: "no-slash") == nil)
        library.delete(id: "local:book")
        #expect(!FileManager.default.fileExists(atPath: folder.path), "removing a copy removes its files")
        await library.awaitPendingWrites()
    }

    @Test("every read and every removal asks the root, never the container itself")
    func everyReadAndRemovalAsksTheRoot() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        try await home.seed()
        let container = home.audioDir.appendingPathComponent("book", isDirectory: true)
        let linked = home.elsewhere.appendingPathComponent("book", isDirectory: true)
        // The same names in both places: only the root decides which is read.
        try home.put("a.m4a", in: container)
        try home.put("a.m4a", in: linked)
        try home.put("cover.jpg", in: linked)
        let root = StandIn(base: home.elsewhere)
        let library = home.library(root: root)
        #expect(library.fileURL(forContentPath: "book/a.m4a")?.standardizedFileURL
                == linked.appendingPathComponent("a.m4a").standardizedFileURL)
        #expect(library.coverURL(forItemId: "local:book")?.standardizedFileURL
                == linked.appendingPathComponent("cover.jpg").standardizedFileURL)
        library.delete(id: "local:book")
        #expect(root.removed == ["local:book"], "the root was asked what removing does")
        #expect(FileManager.default.fileExists(atPath: linked.appendingPathComponent("a.m4a").path),
                "a linked folder stays where it is")
        #expect(library.entries.isEmpty, "the entry itself is gone")
        await library.awaitPendingWrites()
    }

    // MARK: The fence: nobody reaches past the root

    /// Lines of the library that build an entry path from the container
    /// directory itself instead of asking the root.
    nonisolated static func pathsPastTheRoot(in text: String) -> Int {
        text.split(separator: "\n").filter { line in
            !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                && (line.contains("audioDir.appendingPathComponent")
                    // The container is only where the import WRITES; an
                    // entry's folder is the root's answer.
                    || line.contains("container.folder(forEntry:")
                    || line.contains("container.removeFiles("))
        }.count
    }

    @Test("no path past the root, the container name in one place, removal through the root",
          .needsTheSources)
    func nobodyReachesPastTheRoot() throws {
        var namesTheContainer: [String] = []
        var library = ""
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("appendingPathComponent(\"LocalAudio\"") { namesTheContainer.append(file.lastPathComponent) }
            if file.lastPathComponent == "LocalLibrary.swift" { library = text }
        }
        #expect(namesTheContainer == ["LocalLibrary.swift"], "only the assembly of `shared` names the container")
        #expect(Self.pathsPastTheRoot(in: library) == 0, "a read or removal builds its path past the root")
        let remove = try #require(library.range(of: "func delete(id: String)"))
        let deleteBody = library[remove.upperBound...].prefix(400)
        #expect(deleteBody.contains("root.removeFiles(ofEntry:"), "removing an entry does not ask the root")
        // Stock with reason: the import's own cleanup of the folder it is
        // still making (a failed copy, a folder nothing arrived in).
        let removals = library.components(separatedBy: "FileManager.default.removeItem(").count - 1
        #expect(removals == 2, "the import's two cleanups, nothing else; found \(removals)")
    }

    @Test("Calibration lines: the fence sees the old way and leaves the root alone")
    func fenceCalibration() {
        #expect(Self.pathsPastTheRoot(in: "let url = audioDir.appendingPathComponent(contentPath)") == 1)
        #expect(Self.pathsPastTheRoot(in: "audioDir.appendingPathComponent(uuid(entry), isDirectory: true)") == 1)
        #expect(Self.pathsPastTheRoot(in: "root.folder(forEntry: entry.id)?.appendingPathComponent(\"cover.jpg\")") == 0)
        #expect(Self.pathsPastTheRoot(in: "// audioDir.appendingPathComponent(x)") == 0)
        #expect(Self.pathsPastTheRoot(in: "let folder = container.folder(forEntry: \"local:\\(uuid)\")") == 1)
        #expect(Self.pathsPastTheRoot(in: "container.removeFiles(ofEntry: entry.id)") == 1)
        #expect(Self.pathsPastTheRoot(in: "let dir = container.folder(forUUID: uuid)") == 0, "the import writes there")
    }
}
#endif
