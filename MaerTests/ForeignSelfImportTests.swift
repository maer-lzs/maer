// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A device's own export, imported straight back, adopts nothing. The
/// chain store ⇒ export ⇒ reader ⇒ rule, entry by entry, with the
/// stamps the store really writes: fractions of a millisecond, which the
/// exchange form rounds. Measured on a device: 17 of 1395 entries came
/// back "newer" than themselves before moments compared on whole ms.
struct ForeignSelfImportTests {
    private let feed = "https://self.example/rss"
    private let hour: Double = 3600

    private func roundTrip(_ entry: [Double], duration: Double, guid: String = "g1") throws -> ForeignListeningState? {
        guard let state = OPMLExport.exportedState(entry: entry, feedURL: feed, guid: guid,
                                                   enclosureURL: "https://cdn.self.example/\(guid).mp3",
                                                   link: nil, title: "Episode \(guid)", duration: duration) else { return nil }
        let doc = OPMLExport.document(shows: [(title: "Self", feedURL: feed)], states: [state],
                                      generatedAt: Date(timeIntervalSince1970: 1_784_600_000))
        let back = try #require(OvercastOPML.parse(Data(doc.utf8)))
        return back.states.first
    }

    @Test("die eigene Ausfuhr, sofort wieder importiert, uebernimmt 0")
    func ownExportAdoptsNothing() throws {
        let entries: [(entry: [Double], duration: Double)] = [
            ([900, 1_788_449_803_209.24], hour),          // fraction below .5
            ([900, 1_788_449_803_209.74], hour),          // fraction above .5: rounded up by the form
            ([900, 1_788_449_803_209.5], hour),           // exactly half
            ([1_200, 1_788_449_803_209.99, hour], hour),  // with a reference point
            ([hour, 1_788_449_803_209.6, hour], hour),    // finished with duration
            ([ProgressMark.playedSentinel, 1_788_449_803_209.6], 0), // finished without duration
            ([900], hour),                                // old one-value entry: no moment out, fill-only in
            ([900, 0], hour),                             // filled earlier with stamp 0
        ]
        for (index, sample) in entries.enumerated() {
            let back = try #require(try roundTrip(sample.entry, duration: sample.duration, guid: "g\(index)"))
            let adopted = ForeignStateMerge.adoption(local: sample.entry, foreign: back, duration: sample.duration)
            #expect(adopted == nil, "entry \(index) \(sample.entry) came back as \(String(describing: adopted))")
        }
    }

    @Test("nichts Gehoertes geht nicht hinaus")
    func nothingHeardStaysHome() {
        #expect(OPMLExport.exportedState(entry: [0, 1_000], feedURL: feed, guid: "g", enclosureURL: nil,
                                         link: nil, title: nil, duration: hour) == nil)
        #expect(OPMLExport.exportedState(entry: [1, 1_000], feedURL: feed, guid: "g", enclosureURL: nil,
                                         link: nil, title: nil, duration: hour) == nil)
    }

    @Test("ein echt neuerer Fremdstand gewinnt weiterhin, um ganze Millisekunden")
    func genuinelyNewerStillWins() throws {
        let local: [Double] = [900, 1_788_449_803_209.74]
        var back = try #require(try roundTrip(local, duration: hour))
        back.stampedAt = 1_788_449_803_211
        back.position = 300
        let adopted = try #require(ForeignStateMerge.adoption(local: local, foreign: back, duration: hour))
        #expect(adopted.reason == .newer)
        #expect(adopted.entry[0] == 300)
    }

    @Test("die Gruende werden benannt: gefuellt, neuer, ein Wert")
    func reasonsAreNamed() throws {
        let foreign = ForeignListeningState(feedURL: feed, episodeGUID: "g", enclosureURL: nil, episodeLink: nil,
                                            episodeTitle: nil, position: 500, finished: false, stampedAt: 2_000)
        #expect(ForeignStateMerge.adoption(local: nil, foreign: foreign, duration: hour)?.reason == .filled)
        #expect(ForeignStateMerge.adoption(local: [300, 1_000], foreign: foreign, duration: hour)?.reason == .newer)
        #expect(ForeignStateMerge.adoption(local: [300], foreign: foreign, duration: hour)?.reason == .oneValue)
    }
}
#endif
