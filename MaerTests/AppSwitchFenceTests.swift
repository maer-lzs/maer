// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation

/// The fence that keeps the switch colour, in the only form that can.
///
/// The order asked for ONE place. The environment routes (`.toggleStyle` at the
/// root, the UIKit appearance proxy) were built and MEASURED not to arrive.
/// Settings live in a sheet, and a sheet is its own presentation host. So the
/// one place is one TYPE, and this fence is what keeps it one: a bare `Toggle`
/// anywhere in the sources would silently inherit the brand accent again, and
/// nobody would see it until a screenshot.
///
/// Same shape as the quota fence: it watches the CLASS, and it names the file.
@Suite struct AppSwitchFenceTests {

    @Test(.needsTheSources) func nobodyBuildsABareToggle() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var offenders: [String] = []
        var scanned = 0
        for url in SourceTree.files(under: sources) where url.pathExtension == "swift" {
            guard url.lastPathComponent != "AppSwitch.swift",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                // Word boundary: `sourceToggle(` is a helper NAME that happens
                // to end in Toggle. Only a bare construction counts, i.e. a
                // `Toggle(` not preceded by an identifier character.
                guard let range = line.range(of: "Toggle("),
                      !line.contains("func ") else { continue }
                if range.lowerBound > line.startIndex {
                    let before = line[line.index(before: range.lowerBound)]
                    if before.isLetter || before.isNumber || before == "_" { continue }
                }
                offenders.append("\(url.lastPathComponent):\(number + 1)")
            }
        }
        #expect(scanned > 0, "der Zaun hat keine Quelldatei gelesen, also misst er nichts")
        #expect(offenders.isEmpty,
                "diese Stellen bauen einen nackten Toggle statt AppSwitch: \(offenders.joined(separator: ", "))")
    }
}
#endif
