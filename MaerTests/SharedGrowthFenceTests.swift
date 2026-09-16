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
/// MEASURED number back here. One thing it does not say, and it matters when
/// the number is quoted: files that merely LIVE under `Sources/Views` while
/// being stores or rules count too.
///
/// The other thing it used to hide now has its own counter. A grip that moves
/// behind a door LEAVES this count and reappears in the door's file, so the
/// views number alone falls for a move just as it falls for a real cut. **The
/// same count over all of `Sources` tells those two apart:** a move leaves
/// the total standing, grips that COLLAPSE into one lower it.
///
/// | slice | views | all of Sources | shape |
/// |---|---|---|---|
/// | the search deck behind its door | 603 → 599 | 971 → 971 | a move |
/// | the network answer became a value | 599 → 584 | 971 → 956 | 16 collapsed to 1 |
/// | two music-menu grips followed | 584 → 582 | 956 → 954 | 2 collapsed to 0 |
/// | the cover address became a question | 582 → 548 | 954 → 920 | 35 collapsed to 1 |
/// | the rest of the router leaf | 548 → 526 | 920 → 898 | 26 collapsed to 4 |
/// | the calm gate got its own name | 526 → 510 | 898 → 877 | 22 collapsed to 1 |
/// | the two podcast sources merged once | 510 → 505 | 877 → 871 | 9 collapsed to 3 |
/// | the app's housekeeping left the tab host | 505 → 485 | 871 → 869 | mostly a MOVE |
/// | „what we own" got its name | 485 → 477 | 869 → 859 | 12 collapsed to 2 |
/// | fetch-then-download became one action | 477 → 473 | 859 → 857 | 6 collapsed to 1 |
/// | the album page asks the item's source | 473 -> 458 | 857 -> 842 | 16 collapsed to 1 |
/// | the premium mark notifies itself | 458 -> 456 | 842 -> 840 | 4 duties became 1 |
///
/// What the numbers do NOT say is the GAIN, and no counter can: after a
/// collapse someone still knows the singleton, so "decoupled" is never the
/// honest word. Every slice therefore names its gain in one sentence, and by
/// now there are FOUR kinds (this paragraph said two for three slices too
/// long, which is the same defect as any other stale statement beside code):
///
/// 1. Fewer OBSERVERS, which is render time: sixteen subscriptions fell with
///    the network value.
/// 2. A REPLACEABLE seat, which is testability: `ItemRouter` is a value with
///    a closure a witness can substitute, while the network watch stays wired
///    into the root and only its readers became replaceable.
/// 3. LAYERING: the caller stops knowing something it had no business
///    knowing (`ScrollCalm`, the app's housekeeping leaving the tab host).
/// 4. FREEDOM FROM CONTRADICTION: nothing falls at all, and the gain is that
///    two statements about the same fact can no longer drift apart
///    (`canPlayNow` defined AS the negation of `offlineUnavailable`). The one
///    kind where the number does not move, which is exactly why it needs a
///    name.
///
/// Both caps are written back per slice, so a report says without arithmetic
/// which part of a drop was only a move.
struct SharedGrowthFenceTests {
    /// 630 on the day the fence was built and never written back since, while
    /// the measured count had already fallen to 599: the cap would have let
    /// thirty-one new grips through without turning red. 584 after the
    /// network answer became a value, 582 after the two music-menu grips
    /// followed, 548 after the cover address became a question, 526 after the
    /// rest of the router leaf, 510 after the calm gate, 505 after the two
    /// podcast sources were merged in one place, 485 after the app's
    /// housekeeping left the tab host, 477 after „what we own" got its name,
    /// 473 after fetch-then-download became one action, 458 after the album page
    /// asked the item's own music source, 456 after the premium mark, 455 after
    /// the playlist card took its store as a parameter instead of reaching for it,
    /// 453 after the queue page asked the queue it already observes instead of
    /// the singleton twice more. Briefly 454 while the sync page asked the
    /// claim runner itself; back to 453 because that question CREATED the
    /// runner it asked. The page reads the register the factories write
    /// instead, which costs no grip at all and covers all five carriers
    /// rather than one standing in for the rest.
    nonisolated static let stock = 453

    /// The same count over all of `Sources`. 971 before the network value,
    /// 956 after it, 954 after the two music-menu grips, 920 after the cover
    /// address, 898 after the rest of the router leaf, 877 after the calm
    /// gate, 871 after the podcast source merge, 869 after the housekeeping
    /// move. That pair of numbers says the honest thing about that
    /// slice: twenty left the views, two left the app. It was a MOVE with a
    /// small collapse (one duplicated queue-flush pair), and the gain is
    /// layering plus a start-up order that can now be stated and fenced.
    /// 859 after the owned-shows union: here the TOTAL falls further than the
    /// views count (ten against eight), which is the shape of a real collapse
    /// and the opposite of the slice above it. 857 after the one download start, 842 after the album page, 840 after the premium mark: four call sites lost a
    /// duty, and two of them had held it through a local binding that this
    /// counter never saw. 834 after the statistics got their carrier seam:
    /// the store's four grips on the old bridge became one injected
    /// carrier, and the bridge's own grip on the store went with it. The
    /// views count did not move; the gain is a replaceable seat, and a
    /// ceiling that is the carrier's and no longer the pot's. 833 after the
    /// queue moved into the database: the queue page dropped two grips on
    /// the singleton it already observes, the queue gained one on the one
    /// database, and the total still fell. 832 after the playback context
    /// moved into the database: the coordinator wrote "leaves both lists"
    /// twice by hand (start and end), now once behind one door, and the
    /// context gained one grip on the one database. Still 832 after the
    /// sync queue moved into the database: the player's catch enqueued the
    /// same state in both of its branches, now once above the branch, and
    /// the queue gained one grip on the one database. 830 after the sync
    /// history moved into the database: three runners wrote "a run that
    /// moved something is an entry, a clean check is a stamp" by hand with
    /// two grips each, now one door on the seam with one grip each, and
    /// the history gained one grip on the one database. 831 after the local
    /// library moved into the database: the index gained its one grip on the
    /// one database, and nothing in its neighbourhood was written twice, so
    /// nothing fell to pay for it. The first slice in which this count
    /// rose; written back as measured, not hidden behind a default. 832
    /// after the download marks moved into the database, the same way: one
    /// grip on the one database, nothing in the manager's neighbourhood to
    /// fold for it. 833 after the Jellyfin source learned to serve
    /// audiobooks: the gate that decides it is synchronous and reads a
    /// remembered server fact, so the one call that refreshes that fact has
    /// to announce when it changed, and nobody else knows the moment. The
    /// two announcements in that file are one per REASON (a rebuilt client,
    /// a library that appeared or vanished); folding them behind a private
    /// one-liner would lower this number without freeing anything, which is
    /// the move this fence exists to catch.
    /// Kurz 834, als die Dienst-Seite den Anspruchs-Laeufer selbst fragte,
    /// welchen Traeger er haelt; wieder 833, weil dieser Griff den Laeufer
    /// ERZEUGT, den er misst (ein fauler Singleton entsteht beim Lesen, mit
    /// dem Zugang dieses Augenblicks). Die Seite liest jetzt das Register,
    /// das die Fabriken schreiben: kein Griff, und es deckt alle fuenf
    /// Traeger statt eines Stellvertreters.
    /// 832, nachdem der Standby-Zeiger eine Tuer bekam: drei Stellen
    /// schrieben „merken und senden" von Hand (der Griff, seine Ruecknahme,
    /// das Schliessen), jetzt eine. Die Ruecknahme kam in derselben Scheibe
    /// dazu und haette die Zahl sonst auf 834 gehoben; gezahlt ist sie
    /// echt, denn das Paar kann nicht mehr halb geschrieben werden.
    nonisolated static let sourcesStock = 832

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

    @Test("Der Gesamtbestand faellt mit, sonst war es nur ein Umzug")
    func theWholeSourceTreeFallsToo() throws {
        var total = 0
        var perFile: [String: Int] = [:]
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let count = Self.sharedLines(in: try String(contentsOf: file, encoding: .utf8))
            total += count
            if count > 0 { perFile[file.lastPathComponent] = count }
        }
        let heaviest = perFile.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key): \($0.value)" }
        #expect(total <= Self.sourcesStock,
                """
                singletons are reached on \(total) lines across Sources, stock is \
                \(Self.sourcesStock); heaviest: \(heaviest). If the views count fell \
                while this one did not, the grips only moved behind a door and no \
                coupling was solved
                """)
    }
}
#endif
