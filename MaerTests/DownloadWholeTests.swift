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
    @Test("geladen heisst: jede Spur liegt da")
    func loadedMeansEveryTrack() {
        #expect(DownloadManager.isComplete(trackCount: 3, present: [0, 1, 2]))
        #expect(DownloadManager.isComplete(trackCount: 2, present: [0, 1, 7]), "a leftover file is no gap")
        #expect(!DownloadManager.isComplete(trackCount: 3, present: [0, 2]), "a missing track counted as loaded")
        #expect(!DownloadManager.isComplete(trackCount: 0, present: []))
    }

    @Test("beim Start: ein vermerkter Titel mit fehlender Spur zaehlt nicht als geladen und ist wieder ladbar", .needsAudio)
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

    @Test("der Download prueft die Spuren, bevor er den Titel vermerkt", .needsTheSources)
    func theDownloadCountsBeforeItMarks() throws {
        let manager = try FetchAnswerTests.squeezedSource("Sources/Networking/DownloadManager.swift")
        let check = try #require(manager.range(of: "guard Self.isComplete(trackCount: tracks.count, present: present) else {"),
                                 "the download does not count its tracks")
        let mark = try #require(manager.range(of: "await saveDetail(item)"))
        #expect(check.lowerBound < mark.lowerBound, "the title is marked before its tracks are counted")
    }
}
#endif
