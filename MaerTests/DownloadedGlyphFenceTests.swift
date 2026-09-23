// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// "Stored" has one glyph, the filled arrow in a circle; the check in a
/// circle means "heard" and nothing else. Measured before this fence: five
/// places showed a check for a stored title (the podcast download control,
/// the row cover badge, the book detail capsule, the featured card badge)
/// or a green arrow (the album bar). A check glyph within a few lines after
/// a download question counts; the stock is zero.
struct DownloadedGlyphFenceTests {
    /// The questions that decide "this title is stored".
    nonisolated static let downloadQuestions = [
        "isDownloaded(", "isDeletableDownload(", "downloadedBadge", "showsDownloadedState",
    ]

    /// How far below a download question a glyph still belongs to it: the
    /// book detail capsule puts its glyph seven lines under the question.
    nonisolated static let reach = 8

    /// One-based lines of `text` that name a check glyph shortly after a
    /// download question. Comment lines neither ask nor show.
    nonisolated static func checksAfterDownloadQuestions(in text: String) -> [Int] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let code = lines.map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : $0 }
        var found: [Int] = []
        for (index, line) in code.enumerated() where line.contains("\"checkmark") {
            let above = code[max(0, index - reach)..<index]
            if above.contains(where: { line in downloadQuestions.contains { line.contains($0) } }) {
                found.append(index + 1)
            }
        }
        return found
    }

    @Test("Kein Haken zeigt geladen, in keiner Datei", .needsTheSources)
    func noCheckForStored() throws {
        var offenders: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let found = Self.checksAfterDownloadQuestions(in: try String(contentsOf: file, encoding: .utf8))
            if !found.isEmpty { offenders.append("\(file.lastPathComponent): \(found)") }
        }
        #expect(offenders.isEmpty, "a check glyph shows a stored title: \(offenders)")
    }

    @Test("Eichzeilen: der Zaun sieht den Haken nach einer Download-Frage und nur dort")
    func calibration() {
        // The podcast control as it was.
        #expect(Self.checksAfterDownloadQuestions(in: """
            if downloads.isDownloaded(itemId: item.id) {
                if showsDownloadedState {
                    Image(systemName: "checkmark.circle")
            """) == [3])
        // The card badge as it was: a bare check.
        #expect(Self.checksAfterDownloadQuestions(in: """
            } else if downloads.isDownloaded(itemId: itemId) {
                badge {
                    Image(systemName: "checkmark").font(.subheadline.weight(.bold))
            """) == [3])
        // The stored glyph passes.
        #expect(Self.checksAfterDownloadQuestions(in: """
            if downloadManager.isDeletableDownload(itemId: itemId) {
                Image(systemName: "arrow.down.circle.fill")
            """).isEmpty)
        // "Heard" with no download question near it passes.
        #expect(Self.checksAfterDownloadQuestions(in: """
            if isPlayed { Image(systemName: "checkmark.circle.fill").font(.caption) }
            """).isEmpty)
        // A commented question asks nothing.
        #expect(Self.checksAfterDownloadQuestions(in: """
            // if downloads.isDownloaded(itemId: id) {
            Image(systemName: "checkmark.circle.fill")
            """).isEmpty)
        // Past the reach the glyph belongs to something else.
        let far = "if downloads.isDownloaded(itemId: id) {\n"
            + String(repeating: "x\n", count: Self.reach)
            + "Image(systemName: \"checkmark.circle\")"
        #expect(Self.checksAfterDownloadQuestions(in: far).isEmpty)
    }
}
#endif
