// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The item dimension of the listening statistics. The point of the whole
/// design is that there is only ONE count: the day pot is the truth for
/// "listened time", the item pot is the same seconds seen from a different
/// side. Two pots that can drift apart would be the class this project keeps
/// closing. So the invariant gets a test, not a comment.
struct ListeningStatsDimensionTests {

    /// The pure part of the invariant, independent of the store: whatever a
    /// sequence of ticks did, the item sums can never exceed the day sums.
    private func check(_ data: ListeningStatsData) -> Bool {
        data.secondsPerItem.values.reduce(0, +) <= data.secondsPerDay.values.reduce(0, +)
    }

    @Test("die Summe je Item uebersteigt die Tagessumme nie")
    func itemSumNeverExceedsDaySum() {
        var data = ListeningStatsData()
        // Zwei Titel und ein Tick ohne bekannte Kennung. Der landet NUR im
        // Tages-Topf, und genau deshalb ist die Ungleichung nicht Gleichheit.
        data.secondsPerDay["2026-08-19"] = 100
        data.secondsPerItem["radio:rb:a"] = 60
        data.secondsPerItem["rss:x:1"] = 30
        #expect(check(data), "70 von 100 Sekunden sind zugeordnet — erlaubt")

        data.secondsPerItem["radio:rb:b"] = 20
        #expect(!check(data), "110 zugeordnete Sekunden bei 100 gehoerten waeren zwei Wahrheiten")
    }

    @Test("ein Tick zaehlt in BEIDE Toepfe, nicht zweimal in einen")
    func oneTickCountsOnceInEach() {
        var data = ListeningStatsData()
        for _ in 0..<5 {
            data.secondsPerDay["2026-08-19", default: 0] += 1
            data.secondsPerItem["radio:rb:a", default: 0] += 1
        }
        #expect(data.secondsPerDay["2026-08-19"] == 5)
        #expect(data.secondsPerItem["radio:rb:a"] == 5)
        #expect(check(data))
    }

    @Test("ein Tick ohne Kennung faellt nur in den Tages-Topf")
    func tickWithoutIdOnlyCountsTheDay() {
        var data = ListeningStatsData()
        data.secondsPerDay["2026-08-19"] = 10
        // Kein Item-Eintrag: ein Titel, dessen Detail noch nicht steht, darf
        // die gehoerte Zeit nicht verschlucken. Die Tagessumme ist die
        // Wahrheit, die Zuordnung ist die Kuer.
        #expect(data.secondsPerItem.isEmpty)
        #expect(check(data))
    }

    @Test("Bestand ohne Item-Topf liest sich weiter — kein Migrationssprung")
    func legacyDataStillDecodes() throws {
        // Genau die Form, die heute auf der Platte liegt.
        let legacy = #"{"secondsPerDay":{"2026-08-18":3600,"2026-08-19":120}}"#
        let decoded = try JSONDecoder().decode(ListeningStatsData.self,
                                               from: Data(legacy.utf8))
        #expect(decoded.secondsPerDay["2026-08-18"] == 3600)
        #expect(decoded.secondsPerItem.isEmpty, "die neue Dimension startet leer, nicht fehlend")
        #expect(check(decoded))
    }

    @Test("Rangfolge nach ZEIT, Gleichstand stabil")
    func rankingIsByTime() {
        var data = ListeningStatsData()
        data.secondsPerDay["2026-08-19"] = 20_000
        data.secondsPerItem = ["radio:rb:a": 3600, "radio:rb:b": 7200,
                               "rss:x:1": 1800, "radio:rb:c": 3600]
        let radio = data.secondsPerItem
            .filter { $0.key.hasPrefix("radio:") }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map(\.key)
        #expect(radio == ["radio:rb:b", "radio:rb:a", "radio:rb:c"],
                "zwei Stunden schlagen eine, und der Gleichstand bleibt stabil sortiert")
        #expect(check(data))
    }
}
#endif
