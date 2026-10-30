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

    @Test("derselbe Server unter anderer Schreibweise: ein Eintrag, der seine Schreibweise behaelt, und ein Vorschlag")
    func theSameServerUnderAnotherSpellingIsOne() throws {
        let d = fresh()
        KnownServers.remember("https://Audio.Example.com", service: .audiobookshelf, now: 100, defaults: d)
        KnownServers.remember("https://audio.example.com:443/", service: .audiobookshelf, now: 200, defaults: d)
        let all = KnownServers.all(defaults: d)
        #expect(all.map(\.url) == ["https://Audio.Example.com"], "another spelling became a second entry: \(all.map(\.url))")
        #expect(all.first?.lastSuccessAt == 200, "the same server was not refreshed")
        #expect(KnownServers.sameServer("https://Audio.Example.com", "https://audio.example.com:443"),
                "the register answers the same server another way than the one name")
        let filled = fresh()
        KnownServers.backfill([("https://Audio.Example.com", .audiobookshelf), ("https://audio.example.com/", .audiobookshelf)],
                              now: 300, defaults: filled)
        #expect(KnownServers.all(defaults: filled).count == 1, "the backfill took one server twice")

        // Two spellings a build before the one name stored stay as they are
        // (their ids travel as tombstones) and are one suggestion, the newer.
        let older = fresh()
        let stored = [KnownServer(url: "https://Audio.Example.com", service: .audiobookshelf, lastSuccessAt: 100),
                      KnownServer(url: "https://audio.example.com", service: .audiobookshelf, lastSuccessAt: 200),
                      KnownServer(url: "https://audio.example.com", service: .subsonic, lastSuccessAt: 50)]
        older.set(try JSONEncoder().encode(stored), forKey: KnownServers.storeKey)
        #expect(KnownServers.suggestions(for: .audiobookshelf, defaults: older).map(\.id)
                == ["audiobookshelf|https://audio.example.com", "subsonic|https://audio.example.com"],
                "one server stands twice under the field")
        #expect(KnownServers.all(defaults: older).count == 3, "the offer moved the stored entries")
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

    /// Am Geraet stand die Adresse des Sync-Dienstes als Vorschlag im Feld
    /// fuer den Audiobookshelf-Server: die fremde Gruppe nahm jede Art auf.
    @Test("Vorschlaege: der Sync-Dienst steht nie unter einem Medienserver, und kein Medienserver unter dem Sync-Dienst")
    func theSyncServiceAndTheMediaServersStayApart() {
        let d = fresh()
        KnownServers.remember("https://books.maer.fm", service: .audiobookshelf, now: 100, defaults: d)
        KnownServers.remember("https://music.maer.fm", service: .subsonic, now: 200, defaults: d)
        KnownServers.remember("https://sync.maer.fm", service: .maerSync, now: 300, defaults: d)
        #expect(KnownServers.suggestions(for: .audiobookshelf, defaults: d).map(\.url)
                == ["https://books.maer.fm", "https://music.maer.fm"])
        #expect(KnownServers.suggestions(for: .maerSync, defaults: d).map(\.url) == ["https://sync.maer.fm"])
        #expect(KnownServers.sameKind(.jellyfin, .gpodder))
        #expect(!KnownServers.sameKind(.maerSync, .audiobookshelf))
        #expect(!KnownServers.sameKind(.subsonic, .maerSync))
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
