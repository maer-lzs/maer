// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A jump that belongs to an open hits only the title that was opened. An
/// open that is refused leaves the running title as the session's, and a
/// jump after it moved that title and wrote its position.
@MainActor
struct OpenThenSeekTests {
    @Test("ein Sprung nach einem Oeffnen geschieht nur, wenn das Oeffnen steht")
    func theJumpStandsOnlyWithItsOpen() {
        #expect(PlayerCoordinator.jumpStands(opened: "b", active: "b", loaded: "b"))
        #expect(!PlayerCoordinator.jumpStands(opened: "b", active: "a", loaded: "a"),
                "the open of b is refused, a still runs: the jump hits a")
        #expect(!PlayerCoordinator.jumpStands(opened: "b", active: "b", loaded: "a"),
                "the session names b, its player still holds a")
        #expect(!PlayerCoordinator.jumpStands(opened: "b", active: nil, loaded: nil))
    }

    @Test("ein abgewiesenes Oeffnen ohne Sitzung springt nicht und laesst die Sitzung leer")
    func aRefusedOpenJumpsNowhere() async {
        let coordinator = PlayerCoordinator(provider: MockProvider())
        let title = LibraryItem(id: "open-seek-\(UUID().uuidString)", media: nil, addedAt: nil)
        // Offline and not downloaded: the open is refused before anything is
        // taken down.
        await Reachability.$assumed.withValue(false) {
            await coordinator.open(item: title, thenSeekTo: 120)
        }
        #expect(coordinator.viewModel == nil && coordinator.activeItem == nil, "a refused open left a session")
    }

    /// The surfaces that open a title and jump inside it.
    static let jumpers: [String: (count: Int, reason: String)] = [
        "SharedRows.swift": (1, "an album or a server list from one of its songs, for the album page and the car"),
        "BookDetailScreen.swift": (2, "from the beginning, and a chapter of a book that is not the session's"),
        "CatalogSourcePage.swift": (1, "a part of a catalogue series"),
        "PodcastEpisodeDetailView.swift": (1, "a chapter of an episode"),
    ]

    @Test("jede Flaeche, die oeffnet und springt, nimmt die eine Tuer; keine springt auf dem Modell der Sitzung", .needsTheSources)
    func everySurfaceTakesTheOneDoor() throws {
        var jumpers: [String: Int] = [:]
        var bare: [String] = []
        for (file, text) in ProjectFileIntegrityTests.sourceTexts() where file != "PlayerCoordinator.swift" {
            let code = FetchAnswerTests.squeezed(text)
            let count = code.components(separatedBy: "thenSeekTo:").count - 1
            if count > 0 { jumpers[file] = count }
            if code.contains("viewModel?.seek(") { bare.append(file) }
        }
        #expect(jumpers == Self.jumpers.mapValues(\.count), "the surfaces that open and jump: \(jumpers)")
        #expect(bare.isEmpty, "a jump on whatever title the session holds: \(bare)")
        let door = try FetchAnswerTests.squeezedSource("Sources/ViewModels/PlayerCoordinator.swift")
        #expect(door.contains("guard Self.jumpStands(opened: item.id, active: activeItem?.id, loaded: viewModel?.item?.id), let model = viewModel else {"),
                "the door jumps without asking whether its open stands")
    }
}
#endif
