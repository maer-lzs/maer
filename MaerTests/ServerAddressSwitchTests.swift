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
    @Test("a switch is another host, port or path, not the scheme, the spelling or the slash")
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

    @Test("another user at the same address is another account; upper and lower case and an empty field are not")
    func whatIsAnAccountSwitch() {
        let a = "https://jf.a.example"
        #expect(ServerAddressSwitch.isAccountSwitch(fromAddress: a, fromUser: "anna", toAddress: a, toUser: "ben"))
        #expect(!ServerAddressSwitch.isAccountSwitch(fromAddress: a, fromUser: "Anna", toAddress: "HTTPS://jf.a.example/", toUser: " anna "))
        #expect(!ServerAddressSwitch.isAccountSwitch(fromAddress: a, fromUser: "anna", toAddress: a, toUser: ""), "an empty field leaves the user")
        #expect(!ServerAddressSwitch.isAccountSwitch(fromAddress: a, fromUser: "", toAddress: a, toUser: "ben"), "no stored user, nothing to forget")
        #expect(!ServerAddressSwitch.isAccountSwitch(fromAddress: "", fromUser: "anna", toAddress: a, toUser: "ben"), "no stored server, nothing to forget")
        #expect(ServerAddressSwitch.isAccountSwitch(fromAddress: a, fromUser: "anna", toAddress: "https://jf.b.example", toUser: "anna"))
        #expect(ServerAddressSwitch.password(typed: "pw-anna", stored: "pw-anna", from: a, to: a,
                                            fromUser: "anna", toUser: "ben") == ("", true),
                "the password of the stored user went to the new one")
    }

    @Test("the three forms ask the account rule even without an address in the field, and before they write the user", .needsTheSources)
    func theFormsAskBeforeTheUserIsWritten() throws {
        let forms = [("Sources/Views/SubsonicSourceView.swift", "SubsonicProvider.forgetAccessOnSwitch(to: address, user: newUser)", "subsonic"),
                     ("Sources/Views/JellyfinSourceView.swift", "JellyfinProvider.forgetAccessOnSwitch(to: address, user: newUser)", "jellyfin"),
                     ("Sources/Views/GPodderSettingsView.swift", "GPodderSync.forgetAccessOnSwitch(to: address, user: newUser, typed: password)", "gpodder")]
        for (file, ask, family) in forms {
            let form = try FetchAnswerTests.squeezedSource(file)
            #expect(form.contains("let address = trimmedURL.isEmpty ? AppStorageKeys.\(family)ServerURLValue : trimmedURL"),
                    "\(file) asks the rule only with a typed address")
            let asked = try #require(form.range(of: ask), "\(file) does not ask the rule")
            let written = try #require(form.range(of: "AppStorageKeys.\(family)UsernameValue = trimmedUser"), "\(file) writes no user")
            #expect(asked.lowerBound < written.lowerBound, "\(file) writes the user before the rule is asked")
        }
    }

    @Test("Audiobookshelf: a failed question about the user is no switch; two identifiers or an answer without an identifier for a known user are one", .needsTheSources)
    func aFailedAskIsNoSwitch() throws {
        typealias Rule = ServerAddressSwitch
        let a = "https://abs.a.example"
        #expect(!Rule.signInSwitches(fromAddress: a, storedUser: "u-1", toAddress: a, answer: .notRead),
                "a sign-in again whose ask for the user failed dropped the waiting stands")
        #expect(!Rule.signInSwitches(fromAddress: a, storedUser: "", toAddress: a, answer: .notRead))
        #expect(Rule.signInSwitches(fromAddress: a, storedUser: "u-1", toAddress: a, answer: .id("u-2")))
        #expect(!Rule.signInSwitches(fromAddress: a, storedUser: "u-1", toAddress: a, answer: .id("U-1")))
        #expect(Rule.signInSwitches(fromAddress: a, storedUser: "u-1", toAddress: a, answer: .carriesNone),
                "an answer without an id counted as the known user")
        #expect(!Rule.signInSwitches(fromAddress: a, storedUser: "", toAddress: a, answer: .carriesNone),
                "an unknown stored user counted as another")
        #expect(!Rule.signInSwitches(fromAddress: a, storedUser: "", toAddress: a, answer: .id("u-2")),
                "an unknown stored user counted as another")
        #expect(Rule.signInSwitches(fromAddress: a, storedUser: "u-1", toAddress: "https://abs.b.example", answer: .notRead),
                "another server is another account, asked or not")
        let auth = try FetchAnswerTests.squeezedSource("Sources/ViewModels/AuthViewModel.swift")
        #expect(auth.contains("case .id(let stored) = await Self.userId(of: apiClient, side: \"stored\") { formerUser = stored }"),
                "a stored sign-in without a noted user does not ask the server with the stored token")
        #expect(auth.contains("let switched = ServerAddressSwitch.signInSwitches(fromAddress: formerAddress, storedUser: formerUser, toAddress: url.absoluteString, answer: answer)"))
        #expect(auth.contains("if userId != nil || switched { AppStorageKeys.set(userId, for: AppStorageKeys.absSignedInUser) }"),
                "a failed ask erases the noted user")
        #expect(auth.contains("AUTH user id not read side="), "a failed ask for the user passes in silence")
    }

    @Test("the waiting positions of a server go when the user switches, those of other servers stay")
    func theQueuedStandsOfTheServerGo() {
        typealias Update = SyncQueue.PendingUpdate
        let pending: [String: Update] = [
            "li_a": Update(currentTime: 10, duration: 100, isFinished: false, server: "https://abs.a.example"),
            "jf:book:1": Update(currentTime: 20, duration: 100, isFinished: false, server: "https://jf.example"),
            "li_old": Update(currentTime: 30, duration: 100, isFinished: false),
        ]
        let kept = SyncQueue.without(server: ABSServerScope.identity(of: "HTTPS://abs.a.example/"), in: pending)
        #expect(Set(kept.keys) == ["jf:book:1", "li_old"], "the stands of the account before stayed: \(kept.keys.sorted())")
    }

    @Test("Jellyfin: another user at the same address forgets the access, user id and password of the earlier one")
    func anotherUserForgetsTheAccess() {
        let stand = JellyfinStand()
        defer { stand.restore() }
        let url = "https://jf-user-\(UUID().uuidString.prefix(6)).example"
        AppStorageKeys.jellyfinServerURLValue = url
        AppStorageKeys.jellyfinUsernameValue = "anna"
        AppStorageKeys.jellyfinUserIdValue = "uid-anna"
        AppStorageKeys.setJellyfinToken("token-anna")
        AppStorageKeys.setJellyfinPassword("pw-anna")
        #expect(JellyfinProvider.passwordAfterAddress(url, user: "ben", typed: "pw-anna").isEmpty,
                "the field kept the password of the stored user")
        #expect(JellyfinProvider.forgetAccessOnSwitch(to: url, user: "ben"))
        #expect(AppStorageKeys.jellyfinTokenValue.isEmpty, "the access token of the stored user stayed")
        #expect(AppStorageKeys.jellyfinUserIdValue.isEmpty, "the user id of the stored user stayed")
        #expect(AppStorageKeys.jellyfinPasswordValue.isEmpty)
        AppStorageKeys.jellyfinUsernameValue = "ben"
        AppStorageKeys.setJellyfinToken("token-ben")
        #expect(!JellyfinProvider.forgetAccessOnSwitch(to: url, user: "Ben"), "the same user in other letters is no switch")
        #expect(AppStorageKeys.jellyfinTokenValue == "token-ben")
    }

    @Test("gpodder: a new address forgets the password and round state of the stored account, a typed password stays")
    func gpodderForgetsOnAnAddressSwitch() {
        let url = AppStorageKeys.gpodderServerURLValue, user = AppStorageKeys.gpodderUsernameValue
        let password = AppStorageKeys.gpodderPasswordValue
        let synced = AppStorageKeys.stringArray(AppStorageKeys.gpodderLastSyncedFeeds)
        defer {
            AppStorageKeys.gpodderServerURLValue = url
            AppStorageKeys.gpodderUsernameValue = user
            AppStorageKeys.setGpodderPassword(password)
            AppStorageKeys.set(synced, for: AppStorageKeys.gpodderLastSyncedFeeds)
        }
        let a = "https://gp-a-\(UUID().uuidString.prefix(6)).example"
        AppStorageKeys.gpodderServerURLValue = a
        AppStorageKeys.gpodderUsernameValue = "anna"
        AppStorageKeys.setGpodderPassword("pw-anna")
        AppStorageKeys.set(["https://feed.example/a"], for: AppStorageKeys.gpodderLastSyncedFeeds)
        #expect(GPodderSync.forgetAccessOnSwitch(to: a + "/", user: "anna", typed: "pw-anna") == "pw-anna", "the same server is no switch")
        #expect(AppStorageKeys.gpodderPasswordValue == "pw-anna")
        #expect(GPodderSync.forgetAccessOnSwitch(to: "https://gp-b.example", user: "anna", typed: "pw-anna").isEmpty,
                "the field kept the password of the stored server")
        #expect(AppStorageKeys.gpodderPasswordValue.isEmpty, "the stored password would go to the new host")
        #expect(AppStorageKeys.stringArray(AppStorageKeys.gpodderLastSyncedFeeds) == nil, "the round state of the stored account stayed")
        AppStorageKeys.setGpodderPassword("pw-anna")
        #expect(GPodderSync.forgetAccessOnSwitch(to: a, user: "ben", typed: "pw-ben") == "pw-ben", "a password typed for the new account stays")
        #expect(AppStorageKeys.gpodderPasswordValue.isEmpty, "another user kept the stored password")
    }

    @Test("the password field after a new address: empty on a switch if it shows the stored one, a typed one stays")
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

    @Test("Jellyfin: a new address forgets the password of A, one typed for B stays")
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

    @Test("Jellyfin: a new address, no address of the client carries the token of A")
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

    @Test("Jellyfin: only the scheme differs, the token stays")
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

    @Test("Jellyfin: the callback of a client of A writes nothing after the switch, at the same server it does")
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

    @Test("Subsonic with key: a new address, no request carries the key of A")
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

    @Test("Subsonic with token: a new address forgets the password of A, one typed for B stays")
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

    @Test("both forms ask the rule before they write an address, and only they write one", .needsTheSources)
    func bothFormsAskBeforeTheyWrite() throws {
        let jellyfin = try FetchAnswerTests.squeezedSource("Sources/Views/JellyfinSourceView.swift")
        #expect(jellyfin.contains("password = JellyfinProvider.passwordAfterAddress(address, user: newUser, typed: password) JellyfinProvider.forgetAccessOnSwitch(to: address, user: newUser) if !trimmedURL.isEmpty { AppStorageKeys.jellyfinServerURLValue = trimmedURL }"))
        let subsonic = try FetchAnswerTests.squeezedSource("Sources/Views/SubsonicSourceView.swift")
        #expect(subsonic.contains("password = SubsonicProvider.passwordAfterAddress(address, user: newUser, typed: password) SubsonicProvider.forgetAccessOnSwitch(to: address, user: newUser) if !trimmedURL.isEmpty { AppStorageKeys.subsonicServerURLValue = trimmedURL }"))
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
