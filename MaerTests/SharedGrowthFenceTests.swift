// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Views reach singletons (`Something.shared`) in hundreds of places. That is
/// the stock, not the aim: a view that asks a singleton cannot be previewed or
/// tested with anything else in that seat.
///
/// **Counted** are non-comment lines under `Sources/Views` that name `.shared`,
/// and the same count over all of `Sources`. A file that merely LIVES under
/// `Sources/Views` while being a store or a rule counts too, which matters
/// whenever the number is quoted.
///
/// **The rule:** the numbers may only fall, and every slice writes back the
/// MEASURED value. A cap that is not written back stops being one; this fence
/// once sat at 630 while the count was 599, and would have let thirty one new
/// grips through without turning red.
///
/// **The one thing worth remembering**, and it is what the second number is
/// for: a grip that moves behind a door LEAVES the views count and reappears
/// in the door's file, so the views number falls for a move exactly as it
/// falls for a real cut. **If the views count fell and the total did not, it
/// was a move.**
///
/// **What no counter says is the GAIN**, because after a collapse somebody
/// still knows the singleton, so "decoupled" is never the honest word. Four
/// kinds, and every slice names its own: fewer OBSERVERS, which is render
/// time · a REPLACEABLE seat, which is testability · LAYERING, where a caller
/// stops knowing what it had no business knowing · FREEDOM FROM
/// CONTRADICTION, where nothing falls at all and the gain is that two
/// statements about one fact can no longer drift apart.
///
/// **The history of these numbers lives in git and in the reports.** It used
/// to live here, twelve table rows and two paragraphs of it, and that was the
/// only part of this file nobody checked: every line a claim about a count,
/// with no witness. One of them stood wrong for three slices, and one German
/// paragraph had lost its own sentence halfway through. A fence against stale
/// numbers whose head goes stale is the proof of its own rule.
struct SharedGrowthFenceTests {
    /// Grips on singletons in `Sources/Views`, measured 371 (the lock on
    /// every feed surface: Rediscover show and episode, recommendation tile,
    /// an episode on the mixed page, the Continue page ask the one question;
    /// the book page stopped asking the application for its screen; the
    /// episode row and page read the subscriptions through one property, and
    /// the catalogue page asks the stock service it observes, which pays for
    /// the explicit mark, the album's songs, the tap that expands the bar and
    /// the progress report beside the diagnostics; the album's songs moved
    /// on into the music loader, a move, so the total stays; the album and
    /// playlist menu and the Browse page's lanes brought five and paid them:
    /// the songs an album shuffles moved into `CollectionSongs`, a move, the
    /// two queue entries of the collection menu and of the song menu read
    /// the queue through one property each, and the music deck counts the
    /// download stock it already observes).
    /// It has fallen
    /// from 630 over the view cut; four times it was PAID rather than
    /// lowered, by folding or removing a grip in the same neighbourhood (the
    /// page of the listening history paid with a grip nobody read), and it
    /// rose and was written back as measured instead of hidden behind a default.
    nonisolated static let stock = 371

    /// The same count over all of `Sources`, measured 735 (a catalogue
    /// album's songs for the tile menu take the music loader's one way, so
    /// the second grip on the catalogue in `CollectionSongs` fell; before
    /// that 736: the recommendations the Browse page's lane observes and the
    /// two moved songs questions of `CollectionSongs` stayed, three folds
    /// fell; before that 734: the listening
    /// history, the refusal on the Continue card, then the lock on every
    /// feed surface, the search door asking it for the deck, then the player
    /// asking the books shelf whether a title is a book, then the stores of
    /// the carriers' rows naming the one database once for all six, then the
    /// book page leaving the application's scenes alone). This is the
    /// number that tells a move from a collapse, and it is allowed to RISE:
    /// a store that moves into the database gains one grip on the one
    /// database, and if nothing in its neighbourhood was written twice there
    /// is nothing to fold in payment. Written back as measured when it rises
    /// and when it falls, with the reason in the report: a stock above the
    /// count lets that many new grips in unseen.
    nonisolated static let sourcesStock = 735

    nonisolated static func sharedLines(in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//")
                    && trimmed.range(of: "\\.shared\\b", options: .regularExpression) != nil
            }.count
    }

    @Test("Singleton-Zugriffe in Views wachsen nicht", .needsTheSources)
    func viewsDoNotGrowSharedAccess() throws {
        var total = 0
        var perFile: [String: Int] = [:]
        for file in ProjectFileIntegrityTests.sourceFiles() where file.path.contains("/Sources/Views/") {
            let count = Self.sharedLines(in: try String(contentsOf: file, encoding: .utf8))
            total += count
            if count > 0 { perFile[file.lastPathComponent] = count }
        }
        let heaviest = perFile.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key): \($0.value)" }
        let drift = StockDrift.total(total, stock: Self.stock)
        #expect(drift == nil, "views reach singletons on \(total) lines, stock is \(Self.stock) (\(drift ?? "")); heaviest: \(heaviest)")
        #expect(Self.sharedLines(in: "let vm = PlayerViewModel.shared\n// PlayerViewModel.shared in a comment\nlet x = sharedCount") == 1)
    }

    @Test("Der Gesamtbestand faellt mit, sonst war es nur ein Umzug", .needsTheSources)
    func theWholeSourceTreeFallsToo() throws {
        var total = 0
        var perFile: [String: Int] = [:]
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let count = Self.sharedLines(in: try String(contentsOf: file, encoding: .utf8))
            total += count
            if count > 0 { perFile[file.lastPathComponent] = count }
        }
        let heaviest = perFile.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key): \($0.value)" }
        let drift = StockDrift.total(total, stock: Self.sourcesStock)
        #expect(drift == nil,
                """
                singletons are reached on \(total) lines across Sources, stock is \
                \(Self.sourcesStock) (\(drift ?? "")); heaviest: \(heaviest). If the views count fell \
                while this one did not, the grips only moved behind a door and no \
                coupling was solved
                """)
    }
}
#endif
