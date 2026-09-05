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
/// previewed or tested with anything else in that seat. No rebuild before
/// 3.0, but the number may not grow. Counted are non-comment lines under
/// `Sources/Views` that name `.shared`; the stock is the count of the day
/// the fence was built.
struct SharedGrowthFenceTests {
    nonisolated static let stock = 630

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
