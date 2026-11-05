// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// What one music server handed out goes to no other one: a new address
/// for Jellyfin forgets the access token and the user id, and a new
/// address for either forgets the stored password or key. Through
/// the same steps the settings forms take, and through the client the app
/// builds from what is stored.
@MainActor
@Suite(.serialized)
struct ServerAddressSwitchTests {
    @Test("ein Wechsel ist ein anderer Wirt, Port oder Pfad, nicht das Schema, die Schreibweise oder der Schraegstrich")
    func whatIsASwitch() {
        let cases: [(String, String, Bool)] = [
            ("https://jf.a.example", "https://jf.b.example", true),
            ("https://music.example:8096", "https://music.example:8920", true),
            ("https://host.example/jellyfin", "https://host.example/other", true),
            ("http://jf.a.example", "https://jf.a.example", false),
            ("https://JF.A.example/Jellyfin/", "https://jf.a.example/jellyfin", false),
            ("https://jf.a.example:443", "https://jf.a.example", false),
            ("jf.a.example", "https://jf.a.example", false),
            ("", "https://jf.b.example", false),
            ("https://jf.a.example", "", false),
            ("https://jf.a.example", "not a server", true),
        ]
        for (stored, new, expected) in cases {
            #expect(ServerAddressSwitch.isSwitch(from: stored, to: new) == expected, "\(stored) to \(new)")
            // The key is the same rule: two readable addresses switch exactly when their keys differ.
            if let before = ServerAddressSwitch.serverKey(of: stored), let after = ServerAddressSwitch.serverKey(of: new) {
                #expect((before != after) == expected, "the key of \(stored) and \(new)")
            }
        }
        #expect(ServerAddressSwitch.serverKey(of: "") == nil)
        #expect(ServerAddressSwitch.serverKey(of: "not a server") == nil, "an address that does not read has no key")
        #expect(ServerAddressSwitch.serverKey(of: "https://jf.a.example:8096/Jellyfin/") == "jf.a.example:8096/jellyfin")
    }

    /// The stored Jellyfin values, put back after the witness.
    private struct JellyfinStand {
        let url = AppStorageKeys.jellyfinServerURLValue
        let user = AppStorageKeys.jellyfinUsernameValue
        let userId = AppStorageKeys.jellyfinUserIdValue
        let token = AppStorageKeys.jellyfinTokenValue
        let password = AppStorageKeys.jellyfinPasswordValue
        func restore() {
            AppStorageKeys.jellyfinServerURLValue = url
            AppStorageKeys.jellyfinUsernameValue = user
            AppStorageKeys.jellyfinUserIdValue = userId
            AppStorageKeys.setJellyfinToken(token)
            AppStorageKeys.setJellyfinPassword(password)
        }
    }

    /// The steps of the Jellyfin form for a new address: ask, then store;
    /// gives the field's text after the save.
    @discardableResult
    private func saveJellyfin(_ url: String, field: String = "") -> String {
        let kept = JellyfinProvider.passwordAfterAddress(url, typed: field)
        JellyfinProvider.forgetAccessOnSwitch(to: url)
        AppStorageKeys.jellyfinServerURLValue = url
        if !kept.isEmpty { AppStorageKeys.setJellyfinPassword(kept) }
        return kept
    }

    @Test("das Passwortfeld nach einer neuen Adresse: bei einem Wechsel leer, wenn es das gespeicherte zeigt, ein getipptes bleibt")
    func thePasswordFieldAfterANewAddress() {
        let a = "https://jf.a.example", b = "https://jf.b.example"
        #expect(ServerAddressSwitch.password(typed: "pw-a", stored: "pw-a", from: a, to: b) == ("", true),
                "the prefilled password of A goes to B")
        #expect(ServerAddressSwitch.password(typed: "pw-b", stored: "pw-a", from: a, to: b) == ("pw-b", true),
                "a password typed for B is lost")
        #expect(ServerAddressSwitch.password(typed: "pw-a", stored: "pw-a", from: "http://jf.a.example", to: a) == ("pw-a", false),
                "the same server under another scheme loses its password")
        #expect(ServerAddressSwitch.password(typed: "pw-a", stored: "pw-a", from: "", to: b) == ("pw-a", false),
                "a first address has nothing to forget")
    }

    @Test("Jellyfin: eine neue Adresse vergisst das Passwort von A, ein fuer B getipptes bleibt")
    func aNewJellyfinAddressForgetsThePasswordOfA() {
        let stand = JellyfinStand()
        defer { stand.restore() }
        AppStorageKeys.jellyfinServerURLValue = "https://jf.a.example"
        AppStorageKeys.setJellyfinPassword("password-of-a")
        #expect(saveJellyfin("https://jf.b.example", field: "password-of-a").isEmpty, "the field writes the password of A back")
        #expect(AppStorageKeys.jellyfinPasswordValue.isEmpty, "the password of A is still stored")

        AppStorageKeys.jellyfinServerURLValue = "https://jf.a.example"
        AppStorageKeys.setJellyfinPassword("password-of-a")
        #expect(saveJellyfin("https://jf.b.example", field: "password-of-b") == "password-of-b")
        #expect(AppStorageKeys.jellyfinPasswordValue == "password-of-b")

        AppStorageKeys.jellyfinServerURLValue = "http://jf.b.example"
        #expect(saveJellyfin("https://jf.b.example", field: "password-of-b") == "password-of-b", "only the scheme keeps the password")
        #expect(AppStorageKeys.jellyfinPasswordValue == "password-of-b")
    }

    @Test("Jellyfin: eine neue Adresse, keine Adresse des Clients traegt den Token von A")
    func aNewJellyfinAddressCarriesNoTokenOfA() throws {
        let stand = JellyfinStand()
        defer { stand.restore() }
        AppStorageKeys.jellyfinServerURLValue = "https://jf.a.example"
        AppStorageKeys.jellyfinUsernameValue = "hoerer"
        AppStorageKeys.setJellyfinToken("token-of-a")
        AppStorageKeys.jellyfinUserIdValue = "user-of-a"
        let before = try #require(JellyfinProvider.storedClient().imageURL(itemId: "x", maxWidth: 80))
        #expect(before.absoluteString.contains("token-of-a"), "the precondition: the client of A carries its token")

        saveJellyfin("https://jf.b.example")
        let client = JellyfinProvider.storedClient()
        #expect(client.imageURL(itemId: "x", maxWidth: 80) == nil, "an image address of B with the token of A")
        #expect(client.streamURL(songId: "x") == nil, "a stream address of B with the token of A")
        #expect(AppStorageKeys.jellyfinTokenValue.isEmpty && AppStorageKeys.jellyfinUserIdValue.isEmpty,
                "the token and the user id of A are still stored")
    }

    @Test("Jellyfin: nur das Schema anders, der Token bleibt")
    func onlyTheSchemeKeepsTheToken() throws {
        let stand = JellyfinStand()
        defer { stand.restore() }
        AppStorageKeys.jellyfinServerURLValue = "http://jf.a.example"
        AppStorageKeys.jellyfinUsernameValue = "hoerer"
        AppStorageKeys.setJellyfinToken("token-of-a")
        AppStorageKeys.jellyfinUserIdValue = "user-of-a"

        saveJellyfin("https://jf.a.example")
        let image = try #require(JellyfinProvider.storedClient().imageURL(itemId: "x", maxWidth: 80))
        #expect(image.host == "jf.a.example" && image.absoluteString.contains("token-of-a"))
        #expect(AppStorageKeys.jellyfinTokenValue == "token-of-a" && AppStorageKeys.jellyfinUserIdValue == "user-of-a")
    }

    @Test("Jellyfin: der Rueckruf eines Clients von A schreibt nach dem Wechsel nichts, bei demselben Server schon")
    func aFormerClientKeepsNothingAfterTheSwitch() {
        let stand = JellyfinStand()
        defer { stand.restore() }
        AppStorageKeys.jellyfinServerURLValue = "https://jf.a.example"
        AppStorageKeys.jellyfinUsernameValue = "hoerer"
        AppStorageKeys.setJellyfinToken("token-of-a")
        AppStorageKeys.jellyfinUserIdValue = "user-of-a"
        let former = JellyfinProvider.storedClient()

        saveJellyfin("https://jf.b.example")
        // The client of A signs in anew at A while a task still runs.
        former.onTokenRefresh?("fresh-token-of-a", "user-of-a")
        #expect(AppStorageKeys.jellyfinTokenValue.isEmpty && AppStorageKeys.jellyfinUserIdValue.isEmpty,
                "the fresh access of A was stored after the switch")
        #expect(JellyfinProvider.storedClient().imageURL(itemId: "x", maxWidth: 80) == nil,
                "the next client of B carries the access of A")

        // The current server's own fresh sign-in is kept.
        let current = JellyfinProvider.storedClient()
        current.onTokenRefresh?("token-of-b", "user-of-b")
        #expect(AppStorageKeys.jellyfinTokenValue == "token-of-b" && AppStorageKeys.jellyfinUserIdValue == "user-of-b")
    }

    /// The stored Subsonic values, put back after the witness.
    private struct SubsonicStand {
        let url = AppStorageKeys.subsonicServerURLValue
        let user = AppStorageKeys.subsonicUsernameValue
        let password = AppStorageKeys.subsonicPasswordValue
        let servers: [String]
        let modes: [String?]
        init(servers: [String]) {
            self.servers = servers
            modes = servers.map { AppStorageKeys.string("subsonicSignIn.\($0)") }
        }
        func restore() {
            AppStorageKeys.subsonicServerURLValue = url
            AppStorageKeys.subsonicUsernameValue = user
            AppStorageKeys.setSubsonicPassword(password)
            for (server, mode) in zip(servers, modes) { AppStorageKeys.set(mode, for: "subsonicSignIn.\(server)") }
        }
    }

    @Test("Subsonic mit Schluessel: eine neue Adresse, keine Anfrage traegt den Schluessel von A")
    func aNewSubsonicAddressCarriesNoKeyOfA() throws {
        let run = UUID().uuidString.prefix(6).lowercased()
        let serverA = "a-\(run).example/sub", serverB = "b-\(run).example/sub"
        let stand = SubsonicStand(servers: [serverA, serverB])
        defer { stand.restore() }
        AppStorageKeys.subsonicServerURLValue = "https://\(serverA)"
        AppStorageKeys.subsonicUsernameValue = "hoerer"
        AppStorageKeys.setSubsonicPassword("key-of-a")
        SubsonicClient.persistSignIn(.apiKey, server: serverA)
        // B signed in with a key of its own before, the case where the key of
        // A would travel in clear text.
        SubsonicClient.persistSignIn(.apiKey, server: serverB)
        let before = try #require(SubsonicProvider.storedClient()?.mediaURL("stream", ["id": "x"]))
        #expect(before.absoluteString.contains("key-of-a"), "the precondition: A signs in with its key")

        // The form: the field is filled with the stored key, then saved.
        let kept = SubsonicProvider.passwordAfterAddress("https://\(serverB)", typed: "key-of-a")
        AppStorageKeys.subsonicServerURLValue = "https://\(serverB)"
        if !kept.isEmpty { AppStorageKeys.setSubsonicPassword(kept) }
        #expect(kept.isEmpty, "the field writes the key of A back")
        #expect(AppStorageKeys.subsonicPasswordValue.isEmpty, "the key of A is still stored")
        let url = SubsonicProvider.storedClient()?.mediaURL("stream", ["id": "x"])
        #expect(url.map { !$0.absoluteString.contains("key-of-a") } ?? true, "an address of B carries the key of A")

        // A key the person typed for B is B's own and stays.
        AppStorageKeys.subsonicServerURLValue = "https://\(serverA)"
        AppStorageKeys.setSubsonicPassword("key-of-a")
        #expect(SubsonicProvider.passwordAfterAddress("https://\(serverB)", typed: "key-of-b") == "key-of-b")
    }

    @Test("Subsonic mit Token: eine neue Adresse vergisst das Passwort von A, ein fuer B getipptes bleibt")
    func aTokenServerForgetsThePasswordOfA() {
        let run = UUID().uuidString.prefix(6).lowercased()
        let serverA = "a-\(run).example/sub"
        let stand = SubsonicStand(servers: [serverA])
        defer { stand.restore() }
        AppStorageKeys.subsonicServerURLValue = "https://\(serverA)"
        AppStorageKeys.setSubsonicPassword("password-of-a")
        AppStorageKeys.set(nil, for: "subsonicSignIn.\(serverA)")
        #expect(SubsonicProvider.passwordAfterAddress("https://b-\(run).example/sub", typed: "password-of-a").isEmpty,
                "the field writes the password of A back")
        #expect(AppStorageKeys.subsonicPasswordValue.isEmpty, "the password of A is still stored")
        AppStorageKeys.setSubsonicPassword("password-of-a")
        #expect(SubsonicProvider.passwordAfterAddress("https://b-\(run).example/sub", typed: "password-of-b") == "password-of-b")
        AppStorageKeys.setSubsonicPassword("password-of-a")
        #expect(SubsonicProvider.passwordAfterAddress("http://\(serverA)", typed: "password-of-a") == "password-of-a",
                "only the scheme keeps the password")
        #expect(AppStorageKeys.subsonicPasswordValue == "password-of-a")
    }

    @Test("beide Formulare fragen die Regel, bevor sie eine Adresse schreiben, und nur sie schreiben eine", .needsTheSources)
    func bothFormsAskBeforeTheyWrite() throws {
        let jellyfin = try FetchAnswerTests.squeezedSource("Sources/Views/JellyfinSourceView.swift")
        #expect(jellyfin.contains("password = JellyfinProvider.passwordAfterAddress(trimmedURL, typed: password) JellyfinProvider.forgetAccessOnSwitch(to: trimmedURL) AppStorageKeys.jellyfinServerURLValue = trimmedURL"))
        let subsonic = try FetchAnswerTests.squeezedSource("Sources/Views/SubsonicSourceView.swift")
        #expect(subsonic.contains("password = SubsonicProvider.passwordAfterAddress(trimmedURL, typed: password) AppStorageKeys.subsonicServerURLValue = trimmedURL"))
        var writers: [String] = []
        for (file, text) in ProjectFileIntegrityTests.sourceTexts() where file != "UITestSeed.swift" {
            let squeezed = FetchAnswerTests.squeezed(text)
            if squeezed.contains("jellyfinServerURLValue =") || squeezed.contains("subsonicServerURLValue =") {
                writers.append(file)
            }
        }
        #expect(writers.sorted() == ["JellyfinSourceView.swift", "SubsonicSourceView.swift"], "another writer of an address: \(writers)")
    }
}
#endif
