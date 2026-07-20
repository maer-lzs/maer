// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Foundation
import Testing
@testable import ABSPlayer

/// Tests für die Magic-Byte-Erkennung und Endungs-Reparatur der Downloads —
/// der Codepfad hinter den stillen -12864-Abspielfehlern (Endung lügt über
/// den echten Container, AVFoundation vertraut bei lokalen Dateien der Endung).
struct AudioSniffingTests {

    // MARK: - Helfer

    /// Writes bytes to a unique temp file and returns its URL.
    private func tempFile(_ bytes: [UInt8], ext: String = "bin") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sniff-\(UUID().uuidString).\(ext)")
        try Data(bytes).write(to: url)
        return url
    }

    /// ID3v2 container: "ID3" + version/flags + syncsafe size, tag padding,
    /// then the first real frame header.
    private func id3(tagPayload: Int, frame: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = [0x49, 0x44, 0x33, 0x03, 0x00, 0x00]
        bytes += [
            UInt8((tagPayload >> 21) & 0x7F), UInt8((tagPayload >> 14) & 0x7F),
            UInt8((tagPayload >> 7) & 0x7F), UInt8(tagPayload & 0x7F)
        ]
        bytes += [UInt8](repeating: 0, count: tagPayload)
        bytes += frame
        return bytes
    }

    private func sniff(_ bytes: [UInt8]) throws -> String? {
        let url = try tempFile(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        return DownloadManager.sniffedAudioExtension(url)
    }

    // MARK: - Container-Erkennung

    @Test func detectsMP4Family() throws {
        // "ftyp" at offset 4 — the box size before it varies.
        #expect(try sniff([0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x42, 0x20]) == "m4b")
    }

    @Test func detectsFlac() throws {
        #expect(try sniff([0x66, 0x4C, 0x61, 0x43, 0x00, 0x00, 0x00, 0x22]) == "flac")
    }

    @Test func detectsOgg() throws {
        #expect(try sniff([0x4F, 0x67, 0x67, 0x53, 0x00, 0x02, 0x00, 0x00]) == "ogg")
    }

    @Test func detectsWav() throws {
        #expect(try sniff([0x52, 0x49, 0x46, 0x46, 0x24, 0x08, 0x00, 0x00]) == "wav")
    }

    @Test func detectsAiff() throws {
        #expect(try sniff([0x46, 0x4F, 0x52, 0x4D, 0x00, 0x00, 0x00, 0x2E]) == "aiff")
    }

    @Test func detectsCaf() throws {
        #expect(try sniff([0x63, 0x61, 0x66, 0x66, 0x00, 0x01, 0x00, 0x00]) == "caf")
    }

    // MARK: - Rohe Frame-Syncs (ohne Tag)

    @Test func detectsBareMP3() throws {
        // 0xFB: layer bits ≠ 00 → MPEG audio.
        #expect(try sniff([0xFF, 0xFB, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00]) == "mp3")
    }

    @Test func detectsBareADTSAAC() throws {
        // 0xF1: layer bits 00 → ADTS/AAC.
        #expect(try sniff([0xFF, 0xF1, 0x50, 0x80, 0x00, 0x00, 0x00, 0x00]) == "aac")
    }

    // MARK: - ID3-Tag sagt nichts über den Codec

    @Test func id3PrefixedMP3() throws {
        #expect(try sniff(id3(tagPayload: 64, frame: [0xFF, 0xFB])) == "mp3")
    }

    @Test func id3PrefixedADTSAAC() throws {
        #expect(try sniff(id3(tagPayload: 64, frame: [0xFF, 0xF1])) == "aac")
    }

    @Test("Syncsafe-Größe: 7-Bit-Bytes, Tag > 127 Bytes")
    func id3LargeSyncsafeTag() throws {
        // 300 = 0b100101100 → syncsafe [0, 0, 0x02, 0x2C].
        #expect(try sniff(id3(tagPayload: 300, frame: [0xFF, 0xFB])) == "mp3")
    }

    // MARK: - Müll wird abgelehnt

    @Test func rejectsHTMLErrorPage() throws {
        #expect(try sniff([UInt8]("<html><body>error".utf8)) == nil)
    }

    @Test func rejectsJSONErrorPage() throws {
        #expect(try sniff([UInt8]("{\"error\":\"not found\"}".utf8)) == nil)
    }

    @Test func rejectsTooShortFile() throws {
        #expect(try sniff([0x49, 0x44]) == nil)
    }

    @Test func rejectsID3WithGarbageAfterTag() throws {
        #expect(try sniff(id3(tagPayload: 16, frame: [0x00, 0x00])) == nil)
    }

    // MARK: - Frame-Sync-Klassifikation direkt

    @Test(arguments: [
        // (zweites Byte, erwartete Endung): alle Layer-Bit-Kombinationen
        (UInt8(0xF1), "aac"), (UInt8(0xF9), "aac"),
        (UInt8(0xFB), "mp3"), (UInt8(0xFA), "mp3"), (UInt8(0xF3), "mp3"), (UInt8(0xE2), "mp3")
    ])
    func classifiesSyncWords(second: UInt8, expected: String) {
        #expect(DownloadManager.classifyFrameSync([0xFF, second]) == expected)
    }

    @Test func rejectsMissingSyncWord() {
        #expect(DownloadManager.classifyFrameSync([0xFE, 0xFB]) == nil)
        #expect(DownloadManager.classifyFrameSync([0xFF, 0x1B]) == nil)
        #expect(DownloadManager.classifyFrameSync([0xFF]) == nil)
    }

    // MARK: - Endungs-Reparatur

    @Test("MP3-Bytes unter .m4b-Endung werden nach .mp3 umbenannt")
    func repairsLyingExtension() throws {
        let url = try tempFile([0xFF, 0xFB, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00], ext: "m4b")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("mp3"))
        }
        let repaired = DownloadManager.repairedAudioURL(url)
        #expect(repaired?.pathExtension == "mp3")
        #expect(FileManager.default.fileExists(atPath: repaired?.path ?? ""))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("mp4-Familie ist austauschbar: .m4a mit ftyp bleibt unangetastet")
    func keepsMP4FamilyExtension() throws {
        let url = try tempFile([0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70], ext: "m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(DownloadManager.repairedAudioURL(url) == url)
    }

    @Test("Nicht-Audio liefert nil (Datei bleibt für Diagnose liegen)")
    func rejectsGarbageFile() throws {
        let url = try tempFile([UInt8]("<html>".utf8), ext: "mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(DownloadManager.repairedAudioURL(url) == nil)
    }
}
#endif
