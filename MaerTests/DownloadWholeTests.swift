// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Loaded means every track of the title lies here as a file; a download
/// that lacks one fails and is not marked, and a title a build before
/// marked without one is found at the start by the same count.
struct DownloadWholeTests {
    @Test("loaded means: every track lies here")
    func loadedMeansEveryTrack() {
        #expect(DownloadManager.isComplete(trackCount: 3, present: [0, 1, 2]))
        #expect(DownloadManager.isComplete(trackCount: 2, present: [0, 1, 7]), "a leftover file is no gap")
        #expect(!DownloadManager.isComplete(trackCount: 3, present: [0, 2]), "a missing track counted as loaded")
        #expect(!DownloadManager.isComplete(trackCount: 0, present: []))
    }

    @Test("at start: a marked title with a missing track does not count as loaded and can be loaded again", .needsAudio)
    @MainActor
    func aMarkedTitleWithAGapIsFoundAtStart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whole-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Real sound: the count takes only files that read as audio.
        let tone = try TickWorkTests().tone(seconds: 1)
        defer { try? FileManager.default.removeItem(at: tone) }
        let ext = tone.pathExtension
        for (item, indices) in [("li_whole", [0, 1, 2]), ("li_gap", [0, 2])] {
            let dir = root.appendingPathComponent(item, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for index in indices { try FileManager.default.copyItem(at: tone, to: dir.appendingPathComponent("\(index).\(ext)")) }
        }
        let scan = DownloadManager.scanDownloads(downloadsDir: root, marked: ["li_whole", "li_gap"],
                                                 expected: ["li_whole": 3, "li_gap": 3])
        #expect(scan.ids == ["li_whole"], "a title with a gap counted as loaded: \(scan.ids)")
        #expect(scan.remnants["li_gap"] != nil, "the files of the title with a gap are not kept for the next attempt")
        // Without a count the mark stands as before.
        #expect(DownloadManager.scanDownloads(downloadsDir: root, marked: ["li_gap"]).ids == ["li_gap"])
    }

    @Test("the download checks the tracks before it marks the title", .needsTheSources)
    func theDownloadCountsBeforeItMarks() throws {
        let manager = try FetchAnswerTests.squeezedSource("Sources/Networking/DownloadManager.swift")
        let check = try #require(manager.range(of: "guard Self.isComplete(trackCount: tracks.count, present: present) else {"),
                                 "the download does not count its tracks")
        let mark = try #require(manager.range(of: "await saveDetail(item)"))
        #expect(check.lowerBound < mark.lowerBound, "the title is marked before its tracks are counted")
        // One count of "whole" for the end of a download, the start and the
        // question whether a marked title is loaded already.
        #expect(manager.contains("Self.isComplete(trackCount: tracks.count, present: Set(Self.trackMap(in: dir).keys))"),
                "the marked title is judged by a count of its own")
        #expect(!manager.contains(".count >= tracks.count"), "a third form of whole by the number of files")
        // The start scan lists a marked folder once, for the count of its
        // tracks and its bytes.
        let start = try #require(manager.range(of: "static func scanDownloads("))
        let end = try #require(manager.range(of: "static func folderName(of", range: start.upperBound..<manager.endIndex))
        let scan = String(manager[start.upperBound..<end.lowerBound])
        #expect(scan.components(separatedBy: "folderFiles(dir)").count - 1 == 1, "the start scan does not list a folder once")
        #expect(!scan.contains("presentIndices(in:") && !scan.contains("folderContents("),
                "the start scan reads a folder more than once")
    }
}
#endif
