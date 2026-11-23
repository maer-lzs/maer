// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// A genre is one word without its place: "History" became the history of a
/// browser in French and Italian, "Plays" the count of playbacks. Every genre
/// key carries a comment in the catalog, so a translator and a draft know
/// what it means.
struct GenreCommentsFenceTests {
    /// The keys of `String(localized:)` in a piece of source.
    static func keys(in text: String) -> Set<String> {
        Set(text.matches(of: #/String\(localized: "([^"\\]+)"\)/#).map { String($0.output.1) })
    }

    private static func catalog() throws -> [String: Any] {
        let url = SourceTree.root.appendingPathComponent("Sources/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return json?["strings"] as? [String: Any] ?? [:]
    }

    @Test("every genre key of the catalog genres and of the podcast genres carries a comment", .needsTheSources)
    func everyGenreHasAComment() throws {
        let axis = try SourceTree.text(SourceTree.root.appendingPathComponent("Sources/Models/CatalogGenreAxis.swift"))
        let directory = try SourceTree.text(SourceTree.root.appendingPathComponent("Sources/Providers/PodcastDirectory.swift"))
        let podcastGenres = try #require(directory.firstMatch(of: #/enum PodcastGenres \{[\s\S]*?\n\}/#)?.output)
        let genres = Self.keys(in: axis).union(Self.keys(in: String(podcastGenres)))
        #expect(genres.count >= 45, "the fence read only \(genres.count) genres")
        let strings = try Self.catalog()
        let bare = genres.filter { ((strings[$0] as? [String: Any])?["comment"] as? String ?? "").isEmpty }
        #expect(bare.isEmpty, "\(bare.count) genres without a comment: \(bare.sorted())")
        // Calibration: the reader takes a key and leaves code alone.
        #expect(Self.keys(in: #"("drama", String(localized: "Plays")), title: x"#) == ["Plays"])
    }

    @Test("History is the genre in French and Italian, Plays the theatre in French", .needsTheSources)
    func theGenresReadAsGenres() throws {
        let values = try CatalogValues.all()
        func value(_ key: String, _ language: String) -> String? {
            values.first { $0.catalog == "Localizable" && $0.key == key && $0.language == language && $0.part.isEmpty }?.text
        }
        #expect(value("History", "fr") == "Histoire")
        #expect(value("History", "it") == "Storia")
        #expect(value("Plays", "fr") == "Théâtre")
    }
}
#endif
