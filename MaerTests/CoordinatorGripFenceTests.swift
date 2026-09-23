// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS


#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A view gets the player coordinator handed in; it does not reach for the
/// session's. The full player page reached four times although the one
/// view that creates it already held it.
///
/// What stays, each for its reason:
/// - `LibraryView.swift`: the root that creates the observed property.
/// - `RootView.swift`: the root that hands it to the next-steps sheet.
/// - `PlayingNow.swift`: the named door the rows ask „does this play now,
///   here or over there"; it reads the claim sync as well.
/// - `PodcastPlayState.swift`: `podcastSetPlayed`, the ONE place that draws
///   the consequence of marking an episode played, with seven callers.
struct CoordinatorGripFenceTests {
    nonisolated static let stock = ["LibraryView.swift": 1, "RootView.swift": 1,
                                    "PlayingNow.swift": 1, "PodcastPlayState.swift": 1]

    /// Grips on the session's coordinator, by name or through an alias.
    nonisolated static func grips(in text: String) -> Int {
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(IdQuestionDoorFenceTests.withoutComment)
            .joined(separator: "\n")
            .replacing(#/\s*\.\s*/#, with: ".")
        let receivers = ["AppSession.shared"] + IdQuestionDoorFenceTests.aliases(in: code)
        return receivers.reduce(0) { $0 + code.components(separatedBy: "\($1).playerCoordinator").count - 1 }
    }

    @Test("der Zaehler sieht Namen, Alias und Umbruch")
    func theCounterSeesNameAliasAndBreak() {
        #expect(Self.grips(in: "AppSession.shared.playerCoordinator.open(x)") == 1)
        #expect(Self.grips(in: "private static let session = AppSession.shared\nf(Self.session.playerCoordinator)") == 1)
        #expect(Self.grips(in: "AppSession.shared // why\n    .playerCoordinator") == 1)
        #expect(Self.grips(in: "PlayQueueSheet(playerCoordinator: coordinator)") == 0)
    }

    @Test("Ansichten bekommen den Koordinator gereicht, der Bestand faellt nur", .needsTheSources)
    func viewsGetTheCoordinatorHandedIn() throws {
        let files = ProjectFileIntegrityTests.sourceFiles().filter { $0.path.contains("/Sources/Views/") }
        try #require(files.count > 100, "der Zeuge hat den Ansichtsbaum nicht gelesen")
        var found: [String: Int] = [:]
        for file in files {
            let count = Self.grips(in: try String(contentsOf: file, encoding: .utf8))
            if count > 0 { found[file.lastPathComponent] = count }
        }
        #expect(found == Self.stock, "Griffe nach dem Koordinator der Sitzung: \(found.sorted { $0.key < $1.key })")
    }
}
#endif
