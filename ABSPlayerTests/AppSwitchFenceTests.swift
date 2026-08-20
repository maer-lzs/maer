// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation

/// e9a9b05: the fence that keeps the switch colour, in the only form that can.
///
/// The order asked for ONE place. The environment routes (`.toggleStyle` at the
/// root, the UIKit appearance proxy) were built and MEASURED not to arrive —
/// Settings live in a sheet, and a sheet is its own presentation host. So the
/// one place is one TYPE, and this fence is what keeps it one: a bare `Toggle`
/// anywhere in the sources would silently inherit the brand accent again, and
/// nobody would see it until a screenshot.
///
/// Same shape as the quota fence: it watches the CLASS, and it names the file.
@Suite struct AppSwitchFenceTests {

    @Test func nobodyBuildsABareToggle() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: sources,
                                                          includingPropertiesForKeys: nil) else { return }
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard url.lastPathComponent != "AppSwitch.swift",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                // Word boundary: `sourceToggle(` is a helper NAME that happens
                // to end in Toggle — only a bare construction counts, i.e. a
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
        guard scanned > 0 else { return }   // sources unreadable — no verdict
        #expect(offenders.isEmpty,
                "diese Stellen bauen einen nackten Toggle statt AppSwitch: \(offenders.joined(separator: ", "))")
    }
}
#endif
