// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// The library assignment: which half of a server is music and which is books.
/// The promise that has to hold before any feature does is the one about
/// people who never asked for any of this — a source with ONE mode must behave
/// exactly as it did.
struct SourceLibrariesTests {

    private let musicOnly = SourceModes(servesMusic: true, servesAudiobooks: false)
    private let booksOnly = SourceModes(servesMusic: false, servesAudiobooks: true)
    private let both = SourceModes(servesMusic: true, servesAudiobooks: true)
    private let two = [SourceLibrary(id: "1", name: "Musik"),
                       SourceLibrary(id: "2", name: "Hoerbuecher")]

    // MARK: - Auflage 3: ein Modus, ein Verhalten wie heute

    @Test("ein Modus fragt die Bibliotheksliste gar nicht erst")
    func oneModeIgnoresLibraries() {
        // Ohne jede Liste und ohne jede Zuordnung — der Zustand JEDES
        // bestehenden Bestands beim naechsten Start.
        #expect(SourceLibraries.serves(.music, modes: musicOnly, known: [],
                                       assignment: SourceLibraryAssignment()))
        #expect(SourceLibraries.serves(.audiobooks, modes: booksOnly, known: [],
                                       assignment: SourceLibraryAssignment()))
        #expect(SourceLibraries.separability(modes: musicOnly, known: []) == .notNeeded)
        #expect(SourceLibraries.incompleteModes(modes: musicOnly, known: two,
                                                assignment: SourceLibraryAssignment()).isEmpty,
                "wer nur Musik nutzt, darf keine Luecke gemeldet bekommen")
    }

    @Test("ein Modus bedient NUR seinen Typ")
    func oneModeServesOnlyItsType() {
        #expect(!SourceLibraries.serves(.audiobooks, modes: musicOnly, known: two,
                                        assignment: SourceLibraryAssignment()))
        #expect(!SourceLibraries.serves(.music, modes: booksOnly, known: two,
                                        assignment: SourceLibraryAssignment()))
    }

    // MARK: - Auflage 2: G8 bleibt hart

    @Test("zwei Modi ohne Zuordnung bedienen NICHTS — kein leerer Tab")
    func twoModesWithoutAssignmentServeNothing() {
        let empty = SourceLibraryAssignment()
        #expect(!SourceLibraries.serves(.music, modes: both, known: two, assignment: empty))
        #expect(!SourceLibraries.serves(.audiobooks, modes: both, known: two, assignment: empty))
        #expect(SourceLibraries.incompleteModes(modes: both, known: two, assignment: empty)
                == [.music, .audiobooks])
    }

    @Test("halbe Zuordnung: der zugeordnete Typ laeuft, der andere bleibt aus")
    func halfAssignmentServesHalf() {
        let half = SourceLibraryAssignment(byLibrary: ["1": .music])
        #expect(SourceLibraries.serves(.music, modes: both, known: two, assignment: half))
        #expect(!SourceLibraries.serves(.audiobooks, modes: both, known: two, assignment: half))
        #expect(SourceLibraries.incompleteModes(modes: both, known: two, assignment: half)
                == [.audiobooks])
        #expect(SourceLibraries.libraries(for: .music, modes: both, known: two,
                                          assignment: half) == ["1"])
    }

    @Test("volle Zuordnung trennt die beiden Haelften")
    func fullAssignmentSeparates() {
        let full = SourceLibraryAssignment(byLibrary: ["1": .music, "2": .audiobooks])
        #expect(SourceLibraries.libraries(for: .music, modes: both, known: two,
                                          assignment: full) == ["1"])
        #expect(SourceLibraries.libraries(for: .audiobooks, modes: both, known: two,
                                          assignment: full) == ["2"])
        #expect(SourceLibraries.incompleteModes(modes: both, known: two, assignment: full).isEmpty)
    }

    // MARK: - Was der Server nicht kann, kann niemand

    @Test("ein Server mit EINER Bibliothek kann zwei Modi nicht trennen")
    func oneLibraryCannotSeparateTwoModes() {
        let one = [SourceLibrary(id: "1", name: "Music Library")]
        #expect(SourceLibraries.separability(modes: both, known: one) == .impossible(libraryCount: 1))
        // Und es bleibt bei G8: der nicht zugeordnete Typ ist AUS, nicht leer.
        let assignment = SourceLibraryAssignment(byLibrary: ["1": .music])
        #expect(SourceLibraries.serves(.music, modes: both, known: one, assignment: assignment))
        #expect(!SourceLibraries.serves(.audiobooks, modes: both, known: one, assignment: assignment))
    }

    @Test("noch keine Liste ist etwas anderes als keine Bibliotheken")
    func unknownIsNotEmpty() {
        #expect(SourceLibraries.separability(modes: both, known: []) == .unknown)
        #expect(SourceLibraries.separability(modes: both, known: two) == .possible)
    }

    @Test("verschwundene Bibliotheken verlieren ihre Zuordnung")
    func vanishedLibrariesArePruned() {
        let full = SourceLibraryAssignment(byLibrary: ["1": .music, "2": .audiobooks])
        let pruned = full.pruned(toKnown: [SourceLibrary(id: "1", name: "Musik")])
        #expect(pruned.byLibrary == ["1": .music])
        // Sonst saehe der Buch-Modus vollstaendig aus wegen eines Ordners,
        // den es nicht mehr gibt.
        #expect(SourceLibraries.incompleteModes(modes: both,
                                                known: [SourceLibrary(id: "1", name: "Musik")],
                                                assignment: pruned) == [.audiobooks])
    }

    // MARK: - Der Uebergang, nicht der Endzustand

    /// Der teuerste Fehler dieses Zuges, gefunden bevor er ausgeliefert war:
    /// die Verbindung und die Belieferung eines Tabs sind ZWEI Fragen. Haengt
    /// die Verbindung an der zweiten, dann sperrt das Einschalten des zweiten
    /// Modus die Quelle aus ihrer eigenen Einrichtung aus — nichts zugeordnet
    /// heisst „bedient nichts" heisst „kein Client" heisst „Bibliotheksliste
    /// nie abrufbar". Ein Endzustands-Test sieht das nie; der Uebergang ist
    /// der Fall.
    @Test("zweiter Modus an: die Verbindung bleibt, die Tabs bleiben aus")
    func switchingOnTheSecondModeKeepsTheConnection() {
        let tabs: Set<MediaType> = [.music, .audiobooks]
        // Vorher: nur Musik, alles laeuft.
        #expect(SourceLibraries.isLive(modes: musicOnly, enabled: true, enabledTabs: tabs))
        // Der Moment des Umschaltens: beide an, nichts zugeordnet, keine Liste.
        #expect(SourceLibraries.isLive(modes: both, enabled: true, enabledTabs: tabs),
                "sonst faellt der Client weg und die Zuordnung kann nie beginnen")
        #expect(!SourceLibraries.serves(.music, modes: both, known: [],
                                        assignment: SourceLibraryAssignment()),
                "G8 bleibt trotzdem hart: kein Tab ohne Zuordnung")
        #expect(!SourceLibraries.serves(.audiobooks, modes: both, known: [],
                                        assignment: SourceLibraryAssignment()))
    }

    @Test("die Verbindung faellt nur, wenn wirklich nichts gewollt ist")
    func connectionFallsOnlyWhenNothingIsWanted() {
        let tabs: Set<MediaType> = [.music, .audiobooks]
        let none = SourceModes(servesMusic: false, servesAudiobooks: false)
        #expect(!SourceLibraries.isLive(modes: none, enabled: true, enabledTabs: tabs))
        #expect(!SourceLibraries.isLive(modes: both, enabled: false, enabledTabs: tabs))
        // Und wenn der Nutzer den Tab des einzigen Modus abgeschaltet hat.
        #expect(!SourceLibraries.isLive(modes: musicOnly, enabled: true, enabledTabs: [.audiobooks]))
        #expect(SourceLibraries.isLive(modes: both, enabled: true, enabledTabs: [.audiobooks]),
                "ein abgeschalteter Tab von zweien laesst die Quelle leben")
    }

    // MARK: - Auflage 1: die Migration ist keine

    @Test("das Paar liest den Altbestand, ohne etwas zu schreiben")
    func pairReadsLegacyStockWithoutWriting() {
        // Ein Bestand, den nie jemand angefasst hat: NUR der alte Inhaltstyp
        // steht da, die Paar-Schluessel fehlen ganz.
        let suite = UserDefaults(suiteName: "source-libraries-\(UUID().uuidString)")!
        defer { suite.removeSuite(named: suite.description) }
        suite.set("audiobooks", forKey: AppStorageKeys.subsonicContentType)

        // Genau die Praesenz-Pruefung, die die Ablage fuehrt: ein nie
        // geschriebener Schluessel antwortet false, und zweimal false hiesse
        // „speist nichts" — das stille Gegenteil des gespeicherten Wunsches.
        let pairWasWritten = suite.object(forKey: AppStorageKeys.subsonicServesMusicKey) != nil
            || suite.object(forKey: AppStorageKeys.subsonicServesAudiobooksKey) != nil
        #expect(!pairWasWritten)
        let effective = pairWasWritten
            ? SourceModes(servesMusic: suite.bool(forKey: AppStorageKeys.subsonicServesMusicKey),
                          servesAudiobooks: suite.bool(forKey: AppStorageKeys.subsonicServesAudiobooksKey))
            : SourceModes.fromLegacyContentType(suite.string(forKey: AppStorageKeys.subsonicContentType))
        #expect(effective == booksOnly)

        // Und das Lesen hat nichts geschrieben — der zweite Lauf ist derselbe.
        #expect(suite.object(forKey: AppStorageKeys.subsonicServesMusicKey) == nil)
        #expect(suite.object(forKey: AppStorageKeys.subsonicServesAudiobooksKey) == nil)
    }

    @Test("ein geschriebenes Paar schlaegt den Alt-Wert — auch der Leer-Zustand")
    func writtenPairWinsOverLegacy() {
        let suite = UserDefaults(suiteName: "source-libraries-\(UUID().uuidString)")!
        defer { suite.removeSuite(named: suite.description) }
        // Alt-Wert sagt „Musik", das Paar sagt „nichts" — und das Paar gewinnt,
        // sonst speist der Server weiter den Musik-Tab.
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

    @Test("Import-Fall: viele Bibliotheken auf einmal, leeres Delta")
    func importedStockOfLibraries() {
        // Ein frisch verbundener Server liefert seine Ordner in EINEM Zug —
        // kein Delta, keine frische Handlung. Die Zuordnung muss danach
        // trotzdem eine Aussage haben: unzugeordnet ist unzugeordnet.
        let many = (1...50).map { SourceLibrary(id: "\($0)", name: "Ordner \($0)") }
        let empty = SourceLibraryAssignment()
        #expect(SourceLibraries.separability(modes: both, known: many) == .possible)
        #expect(SourceLibraries.incompleteModes(modes: both, known: many, assignment: empty)
                == [.music, .audiobooks])
        // Zweiter Lauf ist ein No-op.
        #expect(empty.pruned(toKnown: many).byLibrary.isEmpty)
    }
}
#endif
