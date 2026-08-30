// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The stamp rule: "we must always stamp in the same time
/// zone, or without one." Stored and compared timestamps are epoch numbers.
/// Zone-free by construction; zones exist in the display only. Text stamps are
/// translated exactly ONCE at the boundary, and the parser takes the offset
/// from the STRING, never silently from the device.
struct StampRuleTests {

    /// The two-strings probe: the same instant, written with an offset and
    /// written as Z, must yield the SAME epoch. If a parser ever falls back to
    /// the device zone, these two drift apart by that offset. And the drift
    /// is invisible on a device standing in UTC, which is why it is a test and
    /// not an inspection.
    @Test("derselbe Zeitpunkt in zwei Schreibweisen ergibt dieselbe Epoche")
    func twoStringsOneInstant() {
        let pairs = [
            ("2026-08-17T14:30:00+02:00", "2026-08-17T12:30:00Z"),
            ("2026-08-17T14:30:00.250+02:00", "2026-08-17T12:30:00.250Z"),
            ("2026-01-05T00:00:00-05:00", "2026-01-05T05:00:00Z"),
        ]
        for (offsetForm, zuluForm) in pairs {
            let a = PlaylistPresentation.changedDate(offsetForm)?.timeIntervalSince1970
            let b = PlaylistPresentation.changedDate(zuluForm)?.timeIntervalSince1970
            #expect(a != nil, "die Offset-Form wurde gar nicht gelesen: \(offsetForm)")
            #expect(a == b, "\(offsetForm) und \(zuluForm) ergeben verschiedene Epochen")
        }
    }

    /// The same for the Jellyfin shape (seven fraction digits, trimmed to
    /// three). The trimming must not eat the offset.
    @Test("die Jellyfin-Form verliert beim Kuerzen den Offset nicht")
    func jellyfinTrimKeepsTheOffset() {
        let withOffset = JellyfinProvider.epochMs(fromJFDate: "2026-08-17T14:30:00.1234567+02:00")
        let asZulu = JellyfinProvider.epochMs(fromJFDate: "2026-08-17T12:30:00.1234567Z")
        #expect(withOffset != nil)
        #expect(withOffset == asZulu)
    }

    /// A fixed format is only fixed WITH a fixed locale: a non-Gregorian
    /// calendar (selectable in iOS settings) formats the same instant as a
    /// different year. Measured defect: the listening statistics used the day
    /// string as a STORED KEY without one, so a calendar change split the
    /// history into two key spaces.
    @Test("ein festes Format braucht ein festes Gebietsschema")
    func fixedFormatNeedsFixedLocale() {
        let instant = Date(timeIntervalSince1970: 1_755_432_600)
        let gregorian = DateFormatter()
        gregorian.locale = Locale(identifier: "en_US_POSIX")
        gregorian.dateFormat = "yyyy-MM-dd"

        let buddhist = DateFormatter()
        buddhist.locale = Locale(identifier: "th_TH_u_ca_buddhist")
        buddhist.dateFormat = "yyyy-MM-dd"

        // The premise of the test: without a fixed locale the SAME format
        // really does produce a different string. If this ever stops being
        // true the fence below is pointless and should be revisited.
        #expect(gregorian.string(from: instant) != buddhist.string(from: instant),
                "die Praemisse traegt nicht mehr — Kalender-Abhaengigkeit pruefen")
    }
}
#endif
