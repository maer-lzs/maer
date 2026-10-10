// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A view that blocks the finger alone stays open to VoiceOver, Voice
/// Control, Switch Control and Full Keyboard Access, which reach it through
/// the accessibility tree. Measured: a text-only episode's invisible play
/// button opened the episode for VoiceOver, and the collapsed sort bar stayed
/// reachable while out of sight. A view that takes no input takes the one
/// grip `takesInput(_:)`; blocking the finger alone is held only where a view
/// is pure decoration over something else and stays readable.
struct InputGripFenceTests {
    /// Files that block the finger alone, each with its reason.
    static let fingerOnly: [String: String] = [
        "RefreshActivityPill.swift": "a status pill over the content: touches pass through, VoiceOver reads it",
        "KindGlyph.swift": "a glyph over artwork: touches reach the tile below, its label is read",
        "PlayerView.swift": "the chapter ticks over the scrubber: drags reach the scrubber below",
        "TabContentLayout.swift": "a placeholder row, hidden from the accessibility tree at its root",
        "ResumeMessageBanner.swift": "the hint pill: touches pass through, VoiceOver reads the hint",
    ]

    /// The lines of code that block hit testing, comments cut away.
    static func hitTestingLines(in code: String) -> [String] {
        SyncContractFenceTests.stripped(code).split(separator: "\n").map(String.init)
            .filter { $0.contains("allowsHitTesting(") }
    }

    @Test("Wer den Finger sperrt, sperrt auch die Bedienungshilfen, ausser bei reinem Schmuck mit Grund", .needsTheSources)
    func noViewBlocksTheFingerAlone() throws {
        let sources = SourceTree.root.appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 100, "the fence read the sources")
        var found: [String: Int] = [:]
        var offenders: [String] = []
        for file in files {
            let lines = Self.hitTestingLines(in: try String(contentsOf: file, encoding: .utf8))
                .filter { !$0.contains("allowsHitTesting(takes)") }
            guard !lines.isEmpty else { continue }
            let name = file.lastPathComponent
            found[name, default: 0] += lines.count
            if Self.fingerOnly[name] == nil { offenders += lines.map { "\(name): \($0.trimmingCharacters(in: .whitespaces))" } }
        }
        #expect(offenders.isEmpty, "these views block the finger alone; take takesInput(_:) or name the reason: \(offenders)")
        let unused = Set(Self.fingerOnly.keys).subtracting(found.keys)
        #expect(unused.isEmpty, "a stock entry without its line goes: \(unused)")
        let library = try String(contentsOf: sources.appendingPathComponent("Views/LibraryView.swift"), encoding: .utf8)
        #expect(Self.hitTestingLines(in: library).filter { !$0.contains("allowsHitTesting(takes)") }.isEmpty,
                "the library view blocks the finger alone again")
        // The reader itself: a comment about the modifier is no use of it.
        let planted = """
        // allowsHitTesting(false) in the view
        .allowsHitTesting(false)
        .takesInput(visible)
        """
        #expect(Self.hitTestingLines(in: planted) == [".allowsHitTesting(false)"])
    }

    /// The text-only episode's button is out of sight and out of the tree,
    /// and the place that fires asks too: a tap that still reaches it opens
    /// nothing.
    @Test("Der unsichtbare Play-Knopf einer Nur-Text-Folge oeffnet nichts, gefragt wird, wo der Knopf feuert", .needsTheSources)
    func theTextOnlyPlayButtonOpensNothing() throws {
        let row = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Podcasts/PodcastComponents.swift"),
            encoding: .utf8))
        #expect(row.contains("EpisodeRowPlayButton(item: item, playerCoordinator: playerCoordinator, playable: !textOnly)"),
                "the row does not tell the button whether there is anything to play")
        let start = try #require(row.range(of: "private func tapped() async {"), "the button's action is gone")
        let action = row[start.upperBound...].prefix(600)
        let ask = try #require(action.range(of: "} else if !playable {"), "the action does not ask whether there is anything to play")
        let open = try #require(action.range(of: "playerCoordinator.open(item:"), "the action opens nothing anymore")
        #expect(ask.lowerBound < open.lowerBound, "the action opens before it asks")
    }
}
#endif
