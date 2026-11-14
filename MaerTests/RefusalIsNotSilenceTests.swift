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
    @Test("Jellyfin: 401 is the sign-in, 403 is the network, every other status is named, and only silence means unreachable")
    func jellyfinTellsRefusalFromSilence() {
        #expect(JellyfinClient.failure(forStatus: 401) == .auth)
        #expect(JellyfinClient.failure(forStatus: 403) == .blockedHere)
        #expect(JellyfinClient.failure(forStatus: 500) == .http(500))
        #expect(JellyfinClient.failure(forStatus: 404) == .http(404))
        // No response object at all: nothing answered, so nothing may be
        // claimed about a password or a network gate.
        #expect(JellyfinClient.failure(forStatus: nil) == .network)
    }

    @Test("Jellyfin: no status except 401 leads to the sign-in sentence")
    func jellyfinNeverBlamesAPasswordForAProxy() {
        // Measured on the CASE, not on the sentence. The first draft of this witness
        // asked whether the text carries the word "password", and failed on
        // its own correct build: the simulator runs in German, the sentence
        // reads "Passwort pruefen". A witness that reads a translated text
        // measures the language and not the matter.
        for status in [403, 404, 429, 500, 502] {
            #expect(JellyfinClient.failure(forStatus: status) != .auth,
                    "HTTP \(status) sagt nichts ueber das Passwort und darf nicht auf den Anmelde-Satz fuehren")
        }
        #expect(JellyfinClient.failure(forStatus: 401) == .auth, "401 ist der einzige Weg dorthin")
        // And the opposite direction to the language: the sentences of the three cases
        // are THREE different ones, whichever language is set.
        let sentences = Set([JellyfinClient.JellyfinError.auth, .blockedHere, .network].compactMap(\.errorDescription))
        #expect(sentences.count == 3, "Anmeldung, Netz-Sperre und Schweigen sagen dasselbe: \(sentences)")
    }

    @Test("Subsonic: 403 is the network, and a 401 on the wire is not a wrong password either")
    func subsonicTellsRefusalFromSilence() {
        #expect(SubsonicClient.failure(forStatus: 403) == .blockedHere)
        #expect(SubsonicClient.failure(forStatus: 500) == .http(500))
        #expect(SubsonicClient.failure(forStatus: 429) == .http(429))
        // The protocol reports a sign-in failure as a body code inside
        // a 200 (40 and 41, see RequestRetryPolicy.subsonicDecision).
        // A 401 on the wire is therefore a door BEFORE the server, and
        // the most common kind of it is a proxy.
        #expect(SubsonicClient.failure(forStatus: 401) == .http(401))
    }

    @Test("Subsonic: no transport status leads to the sentence about the password")
    func subsonicNeverBlamesAPasswordForAProxy() {
        // The opposite direction to Jellyfin, and it was missing: exactly the
        // asymmetry this slice is built against stood in the fence.
        for status in [401, 403, 404, 429, 500, 502] {
            #expect(SubsonicClient.failure(forStatus: status) != .api(code: 40, message: nil),
                    "HTTP \(status) sagt nichts ueber das Passwort")
        }
        // And the body path keeps its sentence, it is the only one that
        // really knows something about the sign-in.
        #expect(SubsonicClient.SubsonicError.api(code: 40, message: nil).errorDescription
                != SubsonicClient.failure(forStatus: 401).errorDescription)
    }

    @Test("Subsonic: the body code and the transport status stay two number spaces")
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

    // The name says what is measured: the same input, the same answer
    // twice. That is determinism, not purity; an impure function
    // with a cache would pass it too. The earlier name promised
    // more than the case holds.
    @Test("both rules answer deterministically: the same input gives the same answer twice")
    func bothRulesAnswerTheSameTwice() {
        for status in [401, 403, 404, 500] {
            #expect(JellyfinClient.failure(forStatus: status) == JellyfinClient.failure(forStatus: status))
            #expect(SubsonicClient.failure(forStatus: status) == SubsonicClient.failure(forStatus: status))
        }
    }
}
#endif
