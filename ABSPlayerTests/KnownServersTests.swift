// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Das Register merkt sich nur, was NACHWEISLICH funktioniert hat.
/// Nie Zugangsdaten, nie automatisch geloescht.
struct KnownServersTests {
    private func fresh() -> UserDefaults {
        UserDefaults(suiteName: "known-servers-\(UUID().uuidString)")!
    }

    @Test("nur Erfolge landen drin, ein zweiter Erfolg frischt auf statt zu doppeln")
    func successOnlyAndNoDuplicates() {
        let d = fresh()
        KnownServers.remember("https://audio.example.com/", service: .audiobookshelf,
                              now: 100, defaults: d)
        KnownServers.remember("https://audio.example.com", service: .audiobookshelf,
                              now: 200, defaults: d)
        let all = KnownServers.all(defaults: d)
        #expect(all.count == 1)                       // trailing slash normalisiert
        #expect(all.first?.lastSuccessAt == 200)      // aufgefrischt
        #expect(all.first?.url == "https://audio.example.com")
    }

    @Test("Vorschlaege: eigener Dienst zuerst, Rest darunter — nach Aktualitaet")
    func ownServiceFirst() {
        let d = fresh()
        KnownServers.remember("https://music.maer.fm", service: .subsonic, now: 100, defaults: d)
        KnownServers.remember("https://pods.maer.fm", service: .gpodder, now: 300, defaults: d)
        KnownServers.remember("https://alt.maer.fm", service: .subsonic, now: 200, defaults: d)
        let out = KnownServers.suggestions(for: .subsonic, defaults: d).map(\.url)
        // Eigener Typ zuerst (neuester zuerst), dann die fremde Domain-Familie.
        #expect(out == ["https://alt.maer.fm", "https://music.maer.fm", "https://pods.maer.fm"])
    }

    @Test("nichts verschwindet von selbst — nur von Hand")
    func neverAutoDeletes() {
        let d = fresh()
        KnownServers.remember("https://a.example", service: .jellyfin, now: 1, defaults: d)
        // Auch ein uralter Eintrag bleibt. Ausfall ist kein Loeschgrund.
        #expect(KnownServers.all(defaults: d).count == 1)
        let entry = KnownServers.all(defaults: d)[0]
        KnownServers.forget(entry, defaults: d)
        #expect(KnownServers.all(defaults: d).isEmpty)
    }

    @Test("die Bestands-Befuellung laeuft genau EINMAL")
    func backfillIsOneOff() {
        let d = fresh()
        KnownServers.backfill([("https://a.example", .audiobookshelf),
                               ("https://a.example", .audiobookshelf),
                               ("https://b.example", .subsonic)], now: 5, defaults: d)
        #expect(KnownServers.all(defaults: d).count == 2)   // Dublette gefaltet
        KnownServers.backfill([("https://c.example", .gpodder)], now: 6, defaults: d)
        #expect(KnownServers.all(defaults: d).count == 2)   // zweiter Lauf tut nichts
    }
}
#endif
