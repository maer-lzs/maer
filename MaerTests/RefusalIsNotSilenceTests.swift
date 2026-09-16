// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// An answer is not silence, and it is not a wrong password either.
///
/// A self-hosted server behind a proxy that serves LAN, mesh or VPN only
/// answers 403 to a device outside the tunnel. Both clients used to make
/// something else of that: Jellyfin said "check username and password" at
/// the sign-in and "could not be reached" at the two browsing doors, the
/// same code with two contradicting sentences; Subsonic turned every
/// status except 401 into "cannot reach the server", so a server that
/// answered 500 looked like a dead network.
///
/// Each client keeps its OWN sentence. What is shared is only the question
/// a status answers, and the rules below are the two places it is asked.
struct RefusalIsNotSilenceTests {
    @Test("Jellyfin: 401 ist die Anmeldung, 403 ist das Netz, jeder andere Status wird genannt, und nur Schweigen heisst unerreichbar")
    func jellyfinTellsRefusalFromSilence() {
        #expect(JellyfinClient.failure(forStatus: 401) == .auth)
        #expect(JellyfinClient.failure(forStatus: 403) == .blockedHere)
        #expect(JellyfinClient.failure(forStatus: 500) == .http(500))
        #expect(JellyfinClient.failure(forStatus: 404) == .http(404))
        // No response object at all: nothing answered, so nothing may be
        // claimed about a password or a network gate.
        #expect(JellyfinClient.failure(forStatus: nil) == .network)
    }

    @Test("Jellyfin: kein Status ausser 401 fuehrt auf den Anmelde-Satz")
    func jellyfinNeverBlamesAPasswordForAProxy() {
        // Gemessen am FALL, nicht am Satz. Der erste Wurf dieses Zeugen
        // fragte, ob der Text das Wort "password" traegt, und riss am
        // eigenen richtigen Bau: der Simulator laeuft deutsch, der Satz
        // heisst "Passwort pruefen". Ein Zeuge, der einen uebersetzten Text
        // liest, misst die Sprache und nicht die Sache.
        for status in [403, 404, 429, 500, 502] {
            #expect(JellyfinClient.failure(forStatus: status) != .auth,
                    "HTTP \(status) sagt nichts ueber das Passwort und darf nicht auf den Anmelde-Satz fuehren")
        }
        #expect(JellyfinClient.failure(forStatus: 401) == .auth, "401 ist der einzige Weg dorthin")
        // Und die Gegenrichtung zur Sprache: die Saetze der drei Faelle
        // sind DREI verschiedene, welche Sprache auch eingestellt ist.
        let sentences = Set([JellyfinClient.JellyfinError.auth, .blockedHere, .network].compactMap(\.errorDescription))
        #expect(sentences.count == 3, "Anmeldung, Netz-Sperre und Schweigen sagen dasselbe: \(sentences)")
    }

    @Test("Subsonic: 403 ist das Netz, 401 bleibt die Anmeldung des Protokolls, ein Serverfehler traegt seine Zahl")
    func subsonicTellsRefusalFromSilence() {
        // 401 keeps becoming the body-level 40: that is the number this
        // protocol uses for a wrong sign-in, and the surfaces read it.
        #expect(SubsonicClient.failure(forStatus: 401) == .api(code: 40, message: nil))
        #expect(SubsonicClient.failure(forStatus: 403) == .blockedHere)
        #expect(SubsonicClient.failure(forStatus: 500) == .http(500))
        #expect(SubsonicClient.failure(forStatus: 429) == .http(429))
    }

    @Test("Subsonic: der Koerper-Code und der Transport-Status bleiben zwei Zahlenraeume")
    func subsonicKeepsItsOwnNumbersApart() throws {
        // The protocol carries its own failures in the body with its own
        // numbers. 40 is "wrong sign-in" THERE and has nothing to do with
        // an HTTP 40x; folding the two together would make one number
        // space out of two that mean different things.
        let body = try #require(SubsonicClient.SubsonicError.api(code: 40, message: nil).errorDescription)
        let transport = try #require(SubsonicClient.SubsonicError.http(40).errorDescription)
        #expect(body != transport, "Koerper-Code und HTTP-Status sagen dasselbe: \(body)")
        #expect(transport.contains("40"), "der Transport-Satz nennt seine Zahl: \(transport)")
    }

    @Test("beide Regeln sind rein: derselbe Eingang gibt zweimal dieselbe Antwort")
    func bothRulesArePure() {
        for status in [401, 403, 404, 500] {
            #expect(JellyfinClient.failure(forStatus: status) == JellyfinClient.failure(forStatus: status))
            #expect(SubsonicClient.failure(forStatus: status) == SubsonicClient.failure(forStatus: status))
        }
    }
}
#endif
