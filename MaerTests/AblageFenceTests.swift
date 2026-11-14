// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Documents go through the seam (`Ablage`) or the rows (`Sources/Storage`).
/// Outside them, every line with `Data(contentsOf:`, `.write(to:`, a file
/// handle (`FileHandle(for`), `createFile(atPath:`, `contents(atPath:`,
/// `copyItem(at:` or `replaceItemAt` is a counted site with a reason in the
/// stock; the stock is the count (`StockDrift`), a new site and a free
/// place are red. Comment lines do not count.
struct AblageFenceTests {
    /// The homes of the seam, each with its reason IN the entry.
    nonisolated static let homes: [(suffix: String, reason: String)] = [
        ("/Sources/Storage/", "die Zeilen-Schicht; sie SCHREIBT die Dateien, an denen die Naht haengt"),
        ("/Ablage.swift", "die Naht selbst"),
        ("/CorruptStore.swift", "legt eine unlesbare Datei beiseite, statt sie durch Leere zu ersetzen"),
    ]

    nonisolated static func isAHome(_ path: String) -> Bool {
        homes.contains { path.contains($0.suffix) }
    }

    nonisolated static func fileSites(in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && Self.fileSpellings.contains { trimmed.contains($0) }
            }.count
    }

    /// Every way a line of the app reads or writes a file by itself.
    nonisolated static let fileSpellings = ["Data(contentsOf:", ".write(to:", "FileHandle(for", "createFile(atPath:",
                                            "contents(atPath:", "copyItem(at:", "replaceItemAt"]

    /// The stock on the day the fence was built (05.09.2026, phase2-ablage),
    /// each with its reason: bytes that are not a document of the app.
    nonisolated static let stock: [String: (count: Int, reason: String)] = [
        "ImageCache.swift": (13, "cover bytes in the image cache, not a document; six of them are test seams that place or read a picture in a tier, two replace a kept cover with the fresh one in one step"),
        "WidgetShared.swift": (7, "the app-group snapshot the widget reads, the Continue rows and the queue's cover thumbnails, outside the app's own container"),
        "PlayerViewModel+Widget.swift": (1, "artwork bytes for the widget in the app group"),
        "Lyrics.swift": (2, "lyrics cache, bytes keyed by song"),
        "UITestSeed.swift": (1, "the silent fixture the harness plays"),
        "PodcastSubscriptions.swift": (1, "the wipe-refused tombstone note"),
        "PodcastSourceView.swift": (1, "the OPML export handed to the share sheet"),
        "PodcastImport.swift": (1, "a foreign OPML file the person picked"),
        "LocalLibrary.swift": (2, "the cover extracted from a local audio file, and the audio files of a local import copied into its folder"),
        "APIClient.swift": (3, "a file mapped for a multipart upload, and the body file of that upload made and written through a handle"),
        "ContinueListeningWidget.swift": (2, "the widget reads the cover bytes the app left in the app group, the title's and its rows'"),
        "PodcastUpNextWidget.swift": (1, "the widget reads the queue's cover thumbnails the app left in the app group"),
        "DownloadManager.swift": (3, "the head of a downloaded file read through a handle to tell audio from an error page; the write of the item id into a download folder's .item-id, raw text beside the tracks: it moves and goes with the folder, and the seam writes JSON by name in one directory and lays an unreadable file aside, which would leave a second file in the folder; the read goes through a file handle with a length limit"),
    ]

    @Test("Files outside the store and the rows: only the stock, each with a reason", .needsTheSources)
    func filesOnlyThroughTheSeam() throws {
        var counts: [String: Int] = [:]
        var seen: Set<String> = []
        // The app and the widget target: a widget reads and writes the app
        // group as much as the app does.
        for folder in ["Sources", "LiveActivityWidget"] {
            for file in SourceTree.files(under: SourceTree.root.appendingPathComponent(folder)) where file.pathExtension == "swift" && !Self.isAHome(file.path) {
                seen.insert(file.lastPathComponent)
                counts[file.lastPathComponent, default: 0] += Self.fileSites(in: try String(contentsOf: file, encoding: .utf8))
            }
        }
        #expect(seen.isSuperset(of: ["WidgetShared.swift", "ContinueListeningWidget.swift"]), "the fence read the app and the widget")
        let drift = StockDrift.findings(counts: counts, stock: Self.stock.mapValues(\.count))
        #expect(drift.isEmpty, "files past the seam, or a stock above the count: \(drift)")
        // The stock names only files that are still there; an entry for a
        // file that left is a claim about nothing and stays green forever.
        let ghosts = Self.stock.keys.filter { !seen.contains($0) }.sorted()
        #expect(ghosts.isEmpty, "the stock names files that are gone: \(ghosts)")
        #expect(Self.fileSites(in: "let d = try? Data(contentsOf: url)\ntry d.write(to: url, options: .atomic)\n// Data(contentsOf: in a comment") == 2)
        #expect(Self.fileSites(in: "let h = try FileHandle(forReadingFrom: url)\nlet w = try FileHandle(forWritingTo: url)\nlet u = try FileHandle(forUpdating: url)\nFileManager.default.createFile(atPath: p, contents: d)\n// FileHandle(forReadingFrom: in a comment") == 4,
                "a file handle and a created file count as sites")
        #expect(Self.fileSites(in: "let d = FileManager.default.contents(atPath: p)\ntry FileManager.default.copyItem(at: a, to: b)\n_ = try FileManager.default.replaceItemAt(a, withItemAt: b)\n// copyItem(at: in a comment") == 3,
                "a read by path, a copy and a swap count as sites")
        #expect(Self.stock.values.allSatisfy { !$0.reason.isEmpty })
    }
}
#endif
