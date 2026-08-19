// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// The form an item was STARTED in, carried in the stock entry.
///
/// The first test is the one the whole design hangs on: the entry is REBUILT on
/// every position write — once a second while playing. A form that is not
/// carried forward would be gone a second after the start, silently, and the
/// row it feeds would stay empty forever without anything looking broken.
struct StartedFormTests {

    private let now: Double = 1_760_000_000_000

    // MARK: - Die Falle, die den Entwurf geformt hat

    @Test("die Form ueberlebt das naechste Positions-Schreiben")
    func formSurvivesTheNextPositionWrite() {
        let started = ProgressMark.entry(position: 0, duration: 0, nowMs: now, form: .album)
        #expect(ProgressMark.markedForm(started) == .album)

        // Genau das, was der Sekunden-Ticker tut.
        var entry = started
        for second in 1...5 {
            entry = ProgressMark.advancing(entry, position: Double(second),
                                           duration: 0, nowMs: now + Double(second) * 1000)
            #expect(ProgressMark.markedForm(entry) == .album,
                    "nach \(second) Sekunden Wiedergabe waere die Form sonst weg")
        }
        #expect(entry[0] == 5)
    }

    @Test("die Form ueberlebt auch das Nachtragen der Dauer")
    func formSurvivesSupplementing() {
        let entry = ProgressMark.entry(position: 120, duration: 0, nowMs: now, form: .album)
        let supplemented = ProgressMark.supplementing(entry, duration: 300)
        #expect(supplemented != nil)
        #expect(ProgressMark.markedForm(supplemented!) == .album)
        #expect(ProgressMark.markedDuration(supplemented!) == 300)
        #expect(supplemented![0] == 120, "Position bleibt unberuehrt")
        #expect(supplemented![1] == now, "Zeitstempel bleibt unberuehrt")
    }

    @Test("eine bekannte Dauer und die Form stehen nebeneinander")
    func durationAndFormCoexist() {
        let entry = ProgressMark.entry(position: 30, duration: 600, nowMs: now, form: .work)
        #expect(ProgressMark.markedDuration(entry) == 600)
        #expect(ProgressMark.markedForm(entry) == .work)
        #expect(ProgressMark.timestamp(entry) == now)
    }

    // MARK: - Der Altbestand wird nicht geraten

    @Test("ein Eintrag ohne Form bleibt, was er war")
    func entryWithoutFormIsUnchanged() {
        let legacy: [Double] = [42, now, 600]
        #expect(ProgressMark.markedForm(legacy) == nil)
        #expect(ContinueSources.belongsInContinue(legacy),
                "Altbestand bleibt in Weiterhoeren — nichts springt")
        let two: [Double] = [42, now]
        #expect(ProgressMark.markedForm(two) == nil)
        #expect(ContinueSources.belongsInContinue(two))
    }

    @Test("die Weiche hat zwei Seiten, und nie beide")
    func theSwitchHasTwoSides() {
        let album = ProgressMark.entry(position: 90, duration: 0, nowMs: now, form: .album)
        let work = ProgressMark.entry(position: 90, duration: 0, nowMs: now, form: .work)
        #expect(!ContinueSources.belongsInContinue(album), "Musik gehoert in Wieder anhoeren")
        #expect(ContinueSources.belongsInContinue(work), "ein Werk gehoert in Weiterhoeren")
    }

    // MARK: - Was die Reihen daraus machen

    @Test("Album-Spuren verlassen Weiterhoeren und erscheinen in Wieder anhoeren")
    func albumTracksSwapRows() {
        let defaults: [String: Any] = [
            "localPosition.lva:album-one": ProgressMark.entry(position: 90, duration: 0,
                                                              nowMs: now, form: .album),
            "localPosition.lva:work-one": ProgressMark.entry(position: 90, duration: 0,
                                                             nowMs: now - 1000, form: .work),
            "localPosition.lva:no-form": [90, now - 2000] as [Double],
        ]
        let cont = ContinueSources.started(in: defaults, serverKnows: []).map(\.id)
        let pos = ContinueSources.positionless(in: defaults, serverKnows: []).map(\.id)
        #expect(cont.sorted() == ["lva:no-form", "lva:work-one"])
        #expect(pos == ["lva:album-one"])
        #expect(Set(cont).isDisjoint(with: Set(pos)), "kein Titel steht in beiden Reihen")
    }

    @Test("die Reihe mischt Katalog, Sender und Server-Alben nach ZEIT")
    func rowMergesByTime() {
        let entries = RecentlyPlayedRow.merged(
            albums: ["sub:album:a"], albumTimes: ["sub:album:a": 300],
            continued: [],
            stations: ["radio:rb:x"], stationTimes: ["radio:rb:x": 100],
            catalog: ["lva:track"], catalogTimes: ["lva:track": 200],
            limit: 10)
        #expect(entries == [.album(id: "sub:album:a"),
                            .catalogTrack(id: "lva:track"),
                            .station(id: "radio:rb:x")])
    }

    @Test("Katalog-Eintraege ohne Zeit ranken hinter allem Datierten")
    func undatedCatalogRanksLast() {
        let entries = RecentlyPlayedRow.merged(
            albums: [], albumTimes: [:], continued: [],
            stations: ["radio:rb:x"], stationTimes: ["radio:rb:x": 100],
            catalog: ["lva:track"], catalogTimes: [:],
            limit: 10)
        #expect(entries == [.station(id: "radio:rb:x"), .catalogTrack(id: "lva:track")])
    }

    // MARK: - Die Ablage

    @Test("die Form landet am Eintrag, ohne Position und Zeit zu verlieren")
    func storeWritesTheFormOntoTheEntry() {
        let name = "started-form-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let id = "lva:some-track"

        ListeningStore.record(id, position: 45, duration: 300, atMs: now, in: defaults)
        ListeningStore.noteStartedForm(id, form: .album, atMs: now + 5000, in: defaults)

        let mark = ListeningStore.mark(id, in: defaults)
        #expect(mark?.position == 45, "die Position bleibt")
        #expect(mark?.updatedAtMs == now, "der Zeitstempel des Eintrags bleibt")
        #expect(mark?.duration == 300, "die gemerkte Dauer bleibt")
        #expect(ListeningStore.startedForm(id, in: defaults) == .album)
    }

    @Test("ein Live-Strom bekommt keine Form — er hat keinen Eintrag")
    func liveStreamsGetNoForm() {
        let name = "started-form-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        ListeningStore.noteStartedForm("radio:rb:a", form: .album, atMs: now, in: defaults)
        #expect(ListeningStore.startedForm("radio:rb:a", in: defaults) == nil,
                "die Klassen-Regel gilt weiter: ein Live-Strom schreibt keinen Stand")
    }
}
#endif
