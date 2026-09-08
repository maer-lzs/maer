// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Views reach singletons (`Something.shared`) in hundreds of places. That
/// is the stock, not the aim: a view that asks a singleton cannot be
/// previewed or tested with anything else in that seat. Counted are
/// non-comment lines under `Sources/Views` that name `.shared`.
///
/// The number may only fall, and every slice of the view cut writes the
/// MEASURED number back here. Two things it does not say, and both matter
/// when it is quoted: a grip that moves behind a door leaves this count and
/// appears in the door's file instead, so a drop can be concentration rather
/// than decoupling; and files that merely LIVE under `Sources/Views` while
/// being stores or rules count too.
struct SharedGrowthFenceTests {
    /// 630 on the day the fence was built and never written back since, while
    /// the measured count had already fallen to 599: the cap would have let
    /// thirty-one new grips through without turning red. 584 after the
    /// network answer became a value, 582 after the two music-menu grips
    /// followed.
    nonisolated static let stock = 582

    nonisolated static func sharedLines(in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//")
                    && trimmed.range(of: "\\.shared\\b", options: .regularExpression) != nil
            }.count
    }

    @Test("Singleton-Zugriffe in Views wachsen nicht")
    func viewsDoNotGrowSharedAccess() throws {
        var total = 0
        var perFile: [String: Int] = [:]
        for file in ProjectFileIntegrityTests.sourceFiles() where file.path.contains("/Sources/Views/") {
            let count = Self.sharedLines(in: try String(contentsOf: file, encoding: .utf8))
            total += count
            if count > 0 { perFile[file.lastPathComponent] = count }
        }
        let heaviest = perFile.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key): \($0.value)" }
        #expect(total <= Self.stock, "views reach singletons on \(total) lines, stock is \(Self.stock); heaviest: \(heaviest)")
        #expect(Self.sharedLines(in: "let vm = PlayerViewModel.shared\n// PlayerViewModel.shared in a comment\nlet x = sharedCount") == 1)
    }
}
#endif
