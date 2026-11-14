// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The library assignment: which half of a server is music and which is books.
/// The promise that has to hold before any feature does is the one about
/// people who never asked for any of this. A source with ONE mode must behave
/// exactly as it did.
struct SourceLibrariesTests {

    private let musicOnly = SourceModes(servesMusic: true, servesAudiobooks: false)
    private let booksOnly = SourceModes(servesMusic: false, servesAudiobooks: true)
    private let both = SourceModes(servesMusic: true, servesAudiobooks: true)
    private let two = [SourceLibrary(id: "1", name: "Musik"),
                       SourceLibrary(id: "2", name: "Hoerbuecher")]

    // MARK: - One mode, one behavior as today

    @Test("one mode does not ask for the library list at all")
    func oneModeIgnoresLibraries() {
        // Without any list and without any assignment. The state of EVERY
        // existing store at the next start.
        #expect(SourceLibraries.serves(.music, modes: musicOnly, known: [],
                                       assignment: SourceLibraryAssignment()))
        #expect(SourceLibraries.serves(.audiobooks, modes: booksOnly, known: [],
                                       assignment: SourceLibraryAssignment()))
        #expect(SourceLibraries.separability(modes: musicOnly, known: []) == .notNeeded)
        #expect(SourceLibraries.incompleteModes(modes: musicOnly, known: two,
                                                assignment: SourceLibraryAssignment()).isEmpty,
                "wer nur Musik nutzt, darf keine Luecke gemeldet bekommen")
    }

    @Test("one mode serves ONLY its type")
    func oneModeServesOnlyItsType() {
        #expect(!SourceLibraries.serves(.audiobooks, modes: musicOnly, known: two,
                                        assignment: SourceLibraryAssignment()))
        #expect(!SourceLibraries.serves(.music, modes: booksOnly, known: two,
                                        assignment: SourceLibraryAssignment()))
    }

    // MARK: - The gate stays hard

    @Test("two modes without an assignment serve NOTHING: no empty tab")
    func twoModesWithoutAssignmentServeNothing() {
        let empty = SourceLibraryAssignment()
        #expect(!SourceLibraries.serves(.music, modes: both, known: two, assignment: empty))
        #expect(!SourceLibraries.serves(.audiobooks, modes: both, known: two, assignment: empty))
        #expect(SourceLibraries.incompleteModes(modes: both, known: two, assignment: empty)
                == [.music, .audiobooks])
    }

    @Test("half an assignment: the assigned type runs, the other stays off")
    func halfAssignmentServesHalf() {
        let half = SourceLibraryAssignment(byLibrary: ["1": .music])
        #expect(SourceLibraries.serves(.music, modes: both, known: two, assignment: half))
        #expect(!SourceLibraries.serves(.audiobooks, modes: both, known: two, assignment: half))
        #expect(SourceLibraries.incompleteModes(modes: both, known: two, assignment: half)
                == [.audiobooks])
        #expect(SourceLibraries.libraries(for: .music, modes: both, known: two,
                                          assignment: half) == ["1"])
    }

    @Test("a full assignment separates the two halves")
    func fullAssignmentSeparates() {
        let full = SourceLibraryAssignment(byLibrary: ["1": .music, "2": .audiobooks])
        #expect(SourceLibraries.libraries(for: .music, modes: both, known: two,
                                          assignment: full) == ["1"])
        #expect(SourceLibraries.libraries(for: .audiobooks, modes: both, known: two,
                                          assignment: full) == ["2"])
        #expect(SourceLibraries.incompleteModes(modes: both, known: two, assignment: full).isEmpty)
    }

    // MARK: - What the server cannot do, nobody can

    @Test("a server with ONE library cannot separate two modes")
    func oneLibraryCannotSeparateTwoModes() {
        let one = [SourceLibrary(id: "1", name: "Music Library")]
        #expect(SourceLibraries.separability(modes: both, known: one) == .impossible(libraryCount: 1))
        // And it stays that way: the unassigned type is OFF, not empty.
        let assignment = SourceLibraryAssignment(byLibrary: ["1": .music])
        #expect(SourceLibraries.serves(.music, modes: both, known: one, assignment: assignment))
        #expect(!SourceLibraries.serves(.audiobooks, modes: both, known: one, assignment: assignment))
    }

    @Test("no list yet is something other than no libraries")
    func unknownIsNotEmpty() {
        #expect(SourceLibraries.separability(modes: both, known: []) == .unknown)
        #expect(SourceLibraries.separability(modes: both, known: two) == .possible)
    }

    /// An unreadable stored list is not silently "none": its bytes rest
    /// under `CorruptStore.asideKey`, it reads as not fetched yet, and only once.
    @Test("an unreadable library list is set aside and reads as not fetched yet")
    func anUnreadableListIsKeptAside() {
        let key = AppStorageKeys.subsonicLibraries
        let defaults = UserDefaults.standard
        let was = defaults.object(forKey: key), aside = defaults.object(forKey: CorruptStore.asideKey(key))
        defer {
            if let was { defaults.set(was, forKey: key) } else { defaults.removeObject(forKey: key) }
            if let aside { defaults.set(aside, forKey: CorruptStore.asideKey(key)) } else { defaults.removeObject(forKey: CorruptStore.asideKey(key)) }
        }
        let broken = Data("not a list".utf8)
        defaults.set(broken, forKey: key)
        #expect(AppStorageKeys.subsonicKnownLibraries.isEmpty)
        #expect(defaults.data(forKey: CorruptStore.asideKey(key)) == broken, "the unreadable list was not kept aside")
        #expect(defaults.data(forKey: key) == nil, "the key stayed, so every read sets aside and logs again")
        #expect(AppStorageKeys.subsonicKnownLibraries.isEmpty)
        // A list the server answers later is read as written.
        AppStorageKeys.subsonicKnownLibraries = two
        #expect(AppStorageKeys.subsonicKnownLibraries == two)
    }

    @Test("vanished libraries lose their assignment")
    func vanishedLibrariesArePruned() {
        let full = SourceLibraryAssignment(byLibrary: ["1": .music, "2": .audiobooks])
        let pruned = full.pruned(toKnown: [SourceLibrary(id: "1", name: "Musik")])
        #expect(pruned.byLibrary == ["1": .music])
        // Otherwise the book mode would look complete because of a folder
        // that no longer exists.
        #expect(SourceLibraries.incompleteModes(modes: both,
                                                known: [SourceLibrary(id: "1", name: "Musik")],
                                                assignment: pruned) == [.audiobooks])
    }

    // MARK: - The transition, not the end state

    /// The connection and the supply of a tab are TWO questions.
    /// If the connection hangs on the second, then switching on the
    /// second mode locks the source out of its own setup: nothing
    /// assigned means no client means library list never fetchable.
    /// An end-state test never sees that; the transition is the case.
    @Test("second mode on: the connection stays, the tabs stay off")
    func switchingOnTheSecondModeKeepsTheConnection() {
        let tabs: Set<MediaType> = [.music, .audiobooks]
        // Before: music only, everything runs.
        #expect(SourceLibraries.isLive(modes: musicOnly, enabled: true, enabledTabs: tabs))
        // The moment of switching: both on, nothing assigned, no list.
        #expect(SourceLibraries.isLive(modes: both, enabled: true, enabledTabs: tabs),
                "sonst faellt der Client weg und die Zuordnung kann nie beginnen")
        #expect(!SourceLibraries.serves(.music, modes: both, known: [],
                                        assignment: SourceLibraryAssignment()),
                "G8 bleibt trotzdem hart: kein Tab ohne Zuordnung")
        #expect(!SourceLibraries.serves(.audiobooks, modes: both, known: [],
                                        assignment: SourceLibraryAssignment()))
    }

    @Test("the connection drops only when really nothing is wanted")
    func connectionFallsOnlyWhenNothingIsWanted() {
        let tabs: Set<MediaType> = [.music, .audiobooks]
        let none = SourceModes(servesMusic: false, servesAudiobooks: false)
        #expect(!SourceLibraries.isLive(modes: none, enabled: true, enabledTabs: tabs))
        #expect(!SourceLibraries.isLive(modes: both, enabled: false, enabledTabs: tabs))
        // And when the user has switched off the tab of the only mode.
        #expect(!SourceLibraries.isLive(modes: musicOnly, enabled: true, enabledTabs: [.audiobooks]))
        #expect(SourceLibraries.isLive(modes: both, enabled: true, enabledTabs: [.audiobooks]),
                "ein abgeschalteter Tab von zweien laesst die Quelle leben")
    }

    // MARK: - The migration is none

    @Test("the pair reads the old store without writing anything")
    func pairReadsLegacyStockWithoutWriting() {
        // A store nobody ever touched: ONLY the old content type
        // is there, the pair keys are missing entirely.
        let suite = UserDefaults(suiteName: "source-libraries-\(UUID().uuidString)")!
        defer { suite.removeSuite(named: suite.description) }
        suite.set("audiobooks", forKey: AppStorageKeys.subsonicContentType)

        // Exactly the presence check the storage performs: a key never
        // written answers false, and false twice would mean
        // feeds nothing. The silent opposite of the stored wish.
        let pairWasWritten = suite.object(forKey: AppStorageKeys.subsonicServesMusicKey) != nil
            || suite.object(forKey: AppStorageKeys.subsonicServesAudiobooksKey) != nil
        #expect(!pairWasWritten)
        let effective = pairWasWritten
            ? SourceModes(servesMusic: suite.bool(forKey: AppStorageKeys.subsonicServesMusicKey),
                          servesAudiobooks: suite.bool(forKey: AppStorageKeys.subsonicServesAudiobooksKey))
            : SourceModes.fromLegacyContentType(suite.string(forKey: AppStorageKeys.subsonicContentType))
        #expect(effective == booksOnly)

        // And the reading wrote nothing. The second run is the same.
        #expect(suite.object(forKey: AppStorageKeys.subsonicServesMusicKey) == nil)
        #expect(suite.object(forKey: AppStorageKeys.subsonicServesAudiobooksKey) == nil)
    }

    @Test("a written pair beats the old value, also the empty state")
    func writtenPairWinsOverLegacy() {
        let suite = UserDefaults(suiteName: "source-libraries-\(UUID().uuidString)")!
        defer { suite.removeSuite(named: suite.description) }
        // The old value names a mode, the pair names none. And the
        // pair wins,
        // otherwise the server keeps feeding the music tab.
        suite.set("music", forKey: AppStorageKeys.subsonicContentType)
        suite.set(false, forKey: AppStorageKeys.subsonicServesMusicKey)
        suite.set(false, forKey: AppStorageKeys.subsonicServesAudiobooksKey)

        let pairWasWritten = suite.object(forKey: AppStorageKeys.subsonicServesMusicKey) != nil
        #expect(pairWasWritten)
        let effective = SourceModes(
            servesMusic: suite.bool(forKey: AppStorageKeys.subsonicServesMusicKey),
            servesAudiobooks: suite.bool(forKey: AppStorageKeys.subsonicServesAudiobooksKey))
        #expect(effective.isEmpty)
    }

    @Test("Import case: many libraries at once, empty delta")
    func importedStockOfLibraries() {
        // A freshly connected server delivers its folders in ONE go.
        // No delta, no fresh action. The assignment must afterwards
        // still have a statement: unassigned is unassigned.
        let many = (1...50).map { SourceLibrary(id: "\($0)", name: "Ordner \($0)") }
        let empty = SourceLibraryAssignment()
        #expect(SourceLibraries.separability(modes: both, known: many) == .possible)
        #expect(SourceLibraries.incompleteModes(modes: both, known: many, assignment: empty)
                == [.music, .audiobooks])
        // The second run is a no-op.
        #expect(empty.pruned(toKnown: many).byLibrary.isEmpty)
    }
}
#endif
