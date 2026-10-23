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

    @Test("P3-3: EIN Geladen-Zeichen, das Symbol eine Konstante, an allen sechs Stellen dieselbe Komponente, nie grau", .needsTheSources)
    func oneDownloadedMark() throws {
        var literal: [String] = []
        var marks: [String: Int] = [:]
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            for line in code where line.contains("\"arrow.down.circle.fill\"") {
                literal.append("\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
            let count = code.filter { $0.contains("DownloadedMark(size:") }.count
            if count > 0 { marks[file.lastPathComponent] = count }
        }
        #expect(literal == ["CoverBadge.swift: static let symbol = \"arrow.down.circle.fill\""],
                "the symbol is written once, as the mark's constant: \(literal)")
        #expect(marks == ["CardDownloadBadge.swift": 1, "BookCoverView.swift": 1, "MediaRowContent.swift": 1,
                          "PodcastComponents.swift": 1, "PlaylistCard.swift": 1, "MusicAlbumView.swift": 1],
                "the six places draw the one mark: \(marks)")
        let badge = try #require(ProjectFileIntegrityTests.sourceFiles().first { $0.lastPathComponent == "CoverBadge.swift" })
        let mark = try #require(functionBody(of: "struct DownloadedMark: View {",
                                             in: try String(contentsOf: badge, encoding: .utf8)))
        #expect(mark.contains(".foregroundStyle(.white, .clear)") && mark.contains(".glyphDisc()"),
                "white on the disc of the tone")
        #expect(!mark.contains(".secondary"), "never a grey glyph (GT-17)")
        #expect(mark.contains("min(rowDiameter, Self.rowCap)") && mark.contains("min(largeDiameter, CoverBadge.detailControl)"),
                "the mark grows with the text only as far as its cover carries it")
    }

    static func view(_ name: String) throws -> String {
        let file = try #require(ProjectFileIntegrityTests.sourceFiles().first { $0.lastPathComponent == name })
        return try String(contentsOf: file, encoding: .utf8)
    }

    @Test("GT-11, GT-10: kein Lade-Pfeil als Zeichen; Laden und Loeschen am langen Druck der Cover und der Playlist-Karte", .needsTheSources)
    func downloadingLivesOnTheLongPress() throws {
        // No arrow image offers a download on a surface. The one left is the
        // Audiobookshelf show's "keep on the server", which saves nothing here.
        var arrows: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() where file.path.contains("/Sources/Views/") {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                && (line.contains("Image(systemName: \"arrow.down.circle\")") || line.contains("Image(systemName: \"arrow.down\")")) {
                arrows.append(file.lastPathComponent)
            }
        }
        #expect(arrows == ["PodcastShowView.swift"], "a download arrow stands on a surface again: \(arrows)")
        let card = try Self.view("CardDownloadBadge.swift")
        let rows = try Self.view("PodcastComponents.swift")
        #expect(!card.contains("startDownload"), "the card starts downloads again")
        #expect(!rows.contains("episode-row-download"), "the row's arrow is back")

        // The covers' long press, of every detail page that has something to load.
        let album = try Self.view("MusicAlbumView.swift")
        let header = try #require(functionBody(of: "private var header: some View {", in: album))
        #expect(header.contains(".contextMenu {") && header.contains("AlbumDownloadMenuItems(itemId: item.id"))
        let episode = try Self.view("PodcastEpisodeDetailView.swift")
        #expect(episode.contains(".podcastEpisodeMenu(item: item, playerCoordinator: playerCoordinator)"))
        let book = try Self.view("BookDetailScreen.swift")
        #expect(book.components(separatedBy: ".contextMenu { coverDownloadMenu }").count - 1 == 3,
                "every layout of the book page carries the long press")
        let bookMenu = try #require(functionBody(of: "private var coverDownloadMenu: some View {", in: book))
        #expect(bookMenu.contains("BookDownloadMenuItems(itemId: entry.id)"), "the book cover's menu downloads")
        let playlist = try Self.view("PlaylistCard.swift")
        #expect(playlist.contains("MusicDownloadMenuItems(itemId: source.id)"), "the playlist card's menu downloads")
    }
}
#endif
