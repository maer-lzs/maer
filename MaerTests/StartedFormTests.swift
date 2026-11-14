// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The form an item was STARTED in, carried in the stock entry.
///
/// The first test is the one the whole design hangs on: the entry is REBUILT on
/// every position write. Once a second while playing. A form that is not
/// carried forward would be gone a second after the start, silently, and the
/// row it feeds would stay empty forever without anything looking broken.
struct StartedFormTests {

    private let now: Double = 1_760_000_000_000

    // MARK: - The trap that shaped the design

    @Test("the form survives the next position write")
    func formSurvivesTheNextPositionWrite() {
        let started = ProgressMark.entry(position: 0, duration: 0, nowMs: now, form: .album)
        #expect(ProgressMark.markedForm(started) == .album)

        // Exactly what the seconds ticker does.
        var entry = started
        for second in 1...5 {
            entry = ProgressMark.advancing(entry, position: Double(second),
                                           duration: 0, nowMs: now + Double(second) * 1000)
            #expect(ProgressMark.markedForm(entry) == .album,
                    "nach \(second) Sekunden Wiedergabe waere die Form sonst weg")
        }
        #expect(entry[0] == 5)
    }

    @Test("the form also survives the adding of the duration")
    func formSurvivesSupplementing() {
        let entry = ProgressMark.entry(position: 120, duration: 0, nowMs: now, form: .album)
        let supplemented = ProgressMark.supplementing(entry, duration: 300)
        #expect(supplemented != nil)
        #expect(ProgressMark.markedForm(supplemented!) == .album)
        #expect(ProgressMark.markedDuration(supplemented!) == 300)
        #expect(supplemented![0] == 120, "Position bleibt unberuehrt")
        #expect(supplemented![1] == now, "Zeitstempel bleibt unberuehrt")
    }

    @Test("a known duration and the form sit side by side")
    func durationAndFormCoexist() {
        let entry = ProgressMark.entry(position: 30, duration: 600, nowMs: now, form: .work)
        #expect(ProgressMark.markedDuration(entry) == 600)
        #expect(ProgressMark.markedForm(entry) == .work)
        #expect(ProgressMark.timestamp(entry) == now)
    }

    // MARK: - The old stock is not guessed

    @Test("an entry without a form stays what it was")
    func entryWithoutFormIsUnchanged() {
        let legacy: [Double] = [42, now, 600]
        #expect(ProgressMark.markedForm(legacy) == nil)
        #expect(ContinueSources.belongsInContinue(legacy),
                "Altbestand bleibt in Weiterhoeren — nichts springt")
        let two: [Double] = [42, now]
        #expect(ProgressMark.markedForm(two) == nil)
        #expect(ContinueSources.belongsInContinue(two))
    }

    @Test("the switch has two sides, and never both")
    func theSwitchHasTwoSides() {
        let album = ProgressMark.entry(position: 90, duration: 0, nowMs: now, form: .album)
        let work = ProgressMark.entry(position: 90, duration: 0, nowMs: now, form: .work)
        #expect(!ContinueSources.belongsInContinue(album), "Musik gehoert in Wieder anhoeren")
        #expect(ContinueSources.belongsInContinue(work), "ein Werk gehoert in Weiterhoeren")
    }

    // MARK: - What the rows make of it

    @Test("Album tracks leave Continue Listening and appear in Listen Again")
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

    /// "Remove from Listen Again" on a catalogue title: the marker hides the
    /// tile, newer progress brings it back, the position itself stays.
    @Test("a Listen Again marker hides the catalogue title, new progress brings it back")
    func hiddenMarkerHidesTheCatalogTile() {
        let now = Date().timeIntervalSince1970 * 1000
        let defaults: [String: Any] = [
            "localPosition.lva:album-h": [90, now, 300, 1] as [Double],
        ]
        let shown = ContinueSources.positionless(in: defaults, serverKnows: []).map(\.id)
        #expect(shown == ["lva:album-h"])
        let markers = ContinueHidden.hiding(id: "lva:album-h", lastUpdate: now, in: [:])
        let hidden = ContinueSources.positionless(in: defaults, serverKnows: [], hiddenMarkers: markers)
        #expect(hidden.isEmpty, "the marker did not hide the tile")
        let later: [String: Any] = ["localPosition.lva:album-h": [120, now + 60_000, 300, 1] as [Double]]
        let back = ContinueSources.positionless(in: later, serverKnows: [], hiddenMarkers: markers).map(\.id)
        #expect(back == ["lva:album-h"], "newer progress must bring the tile back")
    }

    @Test("the row mixes catalogue, stations and server albums by TIME")
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

    @Test("catalogue entries without a time rank behind everything dated")
    func undatedCatalogRanksLast() {
        let entries = RecentlyPlayedRow.merged(
            albums: [], albumTimes: [:], continued: [],
            stations: ["radio:rb:x"], stationTimes: ["radio:rb:x": 100],
            catalog: ["lva:track"], catalogTimes: [:],
            limit: 10)
        #expect(entries == [.station(id: "radio:rb:x"), .catalogTrack(id: "lva:track")])
    }

    // MARK: - The storage

    @Test("the form lands on the entry without losing position and time")
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

    @Test("a live stream gets no form: it has no entry")
    func liveStreamsGetNoForm() {
        let name = "started-form-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        ListeningStore.noteStartedForm("radio:rb:a", form: .album, atMs: now, in: defaults)
        #expect(ListeningStore.startedForm("radio:rb:a", in: defaults) == nil,
                "die Klassen-Regel gilt weiter: ein Live-Strom schreibt keinen Stand")
    }
}

/// The measuring question: what happens to the form when a device is still on an old
/// build and writes three-value entries? That is exactly
/// everyday life. iPhone updated, iPad not yet.
struct StartedFormAcrossDevicesTests {

    private let old: Double = 1_760_000_000_000
    private let new: Double = 1_760_000_100_000

    @Test("the old device wins: the form of the new entry survives locally")
    func oldDeviceWinsButFormSurvivesLocally() {
        // Local: new build, with form. Cloud: old device, three values, younger.
        let local = ["rss:a:1": ProgressMark.entry(position: 10, duration: 300,
                                                  nowMs: old, form: .album)]
        let cloud: [String: [Double]] = ["rss:a:1": [200, new, 300]]
        let out = PodcastCloudSync.merge(local: local, cloud: cloud)
        let written = out.toLocal["rss:a:1"]
        #expect(written?[0] == 200, "die Position des Gewinners kommt an")
        #expect(ProgressMark.markedForm(written ?? []) == .album,
                "die Form ueberlebt aus dem vorhandenen Eintrag — wie die Dauer")
    }

    @Test("the new device wins: the form must TRAVEL ALONG, otherwise it never arrives")
    func newDeviceWinsAndTheFormMustTravel() {
        // Local: new build, with form, younger. Cloud: old device, three values.
        let local = ["rss:a:1": ProgressMark.entry(position: 200, duration: 300,
                                                  nowMs: new, form: .album)]
        let cloud: [String: [Double]] = ["rss:a:1": [10, old, 300]]
        let out = PodcastCloudSync.merge(local: local, cloud: cloud)
        let pushed = out.toCloud["rss:a:1"]
        #expect(pushed?[0] == 200)
        #expect(ProgressMark.markedForm(pushed ?? []) == .album,
                "ohne das erreicht die Form NIE ein zweites Geraet")
    }

    @Test("no entry at all in the cloud: the form still travels along")
    func formTravelsWhenTheCloudKnowsNothing() {
        let local = ["lva:track": ProgressMark.entry(position: 90, duration: 0,
                                                    nowMs: new, form: .album)]
        let out = PodcastCloudSync.merge(local: local, cloud: [:])
        #expect(ProgressMark.markedForm(out.toCloud["lva:track"] ?? []) == .album)
    }
}
#endif
