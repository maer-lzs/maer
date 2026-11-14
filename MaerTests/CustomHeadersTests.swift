// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Synchronization
import os
@testable import Maer

/// The headers a person enters in a server sheet: what the rule keeps, how
/// they move with the address, and the sentence of a guard in front.
@Suite(.serialized)
struct CustomHeadersTests {
    typealias Keys = ServerHeadersWayTests.MemoryKeys
    typealias Host = HeaderRedirectMeasureTests.RecordingHost

    @Test("Input: reserved names, names that are not a token and values with control characters are rejected, spaces at the edge are trimmed")
    func theEntryRule() {
        func refusal(_ name: String, _ value: String) -> ServerHeaderRule.Refusal? {
            ServerHeaderRule.refusal(of: ServerHeaderRule.cleaned(name: name, value: value))
        }
        #expect(refusal("CF-Access-Client-Id", "abc.access") == nil)
        #expect(refusal("Authorization", "Bearer x") == .reservedName)
        #expect(refusal("user-agent", "x") == .reservedName)
        #expect(refusal("X Gate", "x") == .notAToken, "a name with a space")
        #expect(refusal("X-Gate:", "x") == .notAToken, "a name with a colon")
        #expect(refusal("X-Gate", "a\r\nX-Other: b") == .unsafeValue, "a value with CR LF")
        #expect(refusal("X-Gate", "a\nb") == .unsafeValue, "a value with LF")
        #expect(refusal("X-Gate", "a\u{0}b") == .unsafeValue, "a value with another control character")
        let pasted = ServerHeaderRule.cleaned(name: " X-Gate ", value: "secret-value  ")
        #expect(pasted == .init(name: "X-Gate", value: "secret-value"), "the spaces of a pasted value stayed")
    }

    @Test("Input: the address of the field becomes the address of the table, https without a scheme")
    func theTypedAddress() {
        #expect(ServerHeaderRule.base(typed: "music.example.com")?.absoluteString == "https://music.example.com")
        #expect(ServerHeaderRule.base(typed: " http://10.0.0.2:4533/navidrome ")?.absoluteString == "http://10.0.0.2:4533/navidrome")
        #expect(ServerHeaderRule.base(typed: "") == nil)
        #expect(ServerHeaderRule.base(typed: "ftp://files.example.com") == nil)
    }

    @Test("Input: the sentence under a rejected row, none under a half-filled one")
    @MainActor
    func theSentenceUnderARow() {
        var row = CustomHeadersSection.Row()
        row.name = "X-Gate"
        #expect(CustomHeadersSection.sentence(for: row) == nil, "a row without its value spoke already")
        row.value = "a\nb"
        #expect(CustomHeadersSection.sentence(for: row) == String(localized: "A header value cannot contain a line break."))
        row.name = "Cookie"
        row.value = "x"
        #expect(CustomHeadersSection.sentence(for: row) == String(localized: "The app sets this header itself."))
    }

    @Test("Move: when the address changes, the headers move along, nothing is left under the old one, and a request to the old one carries nothing")
    func theHeadersMoveWithTheAddress() throws {
        let keys = Keys()
        let old = try #require(URL(string: "https://old-\(UUID().uuidString.prefix(6)).example/abs"))
        let new = try #require(URL(string: "https://new-\(UUID().uuidString.prefix(6)).example/abs"))
        let header = ServerHeaderRule.Header(name: ServerHeadersWayTests.name, value: ServerHeadersWayTests.value)
        try ServerHeaders.$witness.withValue(keys.keys()) {
            ServerHeaders.set([header], for: old)
            try #require(ServerHeaders.stored(for: old) == [header], "the precondition: the old address has the header")
            #expect(ServerHeaders.move(from: old, to: new) == .moved)
            #expect(ServerHeaders.stored(for: new) == [header], "the header did not move to the new address")
            #expect(ServerHeaders.stored(for: old) == [], "the header stayed under the old address")
            let entries = try #require(ServerHeaders.entries())
            let request = ServerHeaderRule.applied(URLRequest(url: old.appendingPathComponent("api/me")), entries: entries)
            #expect(request.value(forHTTPHeaderField: ServerHeadersWayTests.name) == nil, "a request to the old address carries the header")
        }
        #expect(keys.state.withLock { $0.bases } == [ServerHeaders.address(new)])
    }

    @Test("Move: onto a server with its own headers nothing moves, both keep theirs, and a request to the target carries its own")
    func noMoveOntoAServerWithItsOwnHeaders() throws {
        let keys = Keys()
        let old = try #require(URL(string: "https://old-\(UUID().uuidString.prefix(6)).example"))
        let new = try #require(URL(string: "https://new-\(UUID().uuidString.prefix(6)).example"))
        let theirs = ServerHeaderRule.Header(name: "X-Old-Gate", value: "old-\(UUID().uuidString.prefix(6))")
        let own = ServerHeaderRule.Header(name: "X-New-Gate", value: "new-\(UUID().uuidString.prefix(6))")
        try ServerHeaders.$witness.withValue(keys.keys()) {
            ServerHeaders.set([theirs], for: old)
            ServerHeaders.set([own], for: new)
            #expect(ServerHeaders.move(from: old, to: new) == .targetHasOwn)
            #expect(ServerHeaders.stored(for: new) == [own], "the target lost its own headers")
            #expect(ServerHeaders.stored(for: old) == [theirs], "the old address lost its headers")
            let entries = try #require(ServerHeaders.entries())
            let request = ServerHeaderRule.applied(URLRequest(url: new.appendingPathComponent("api/me")), entries: entries)
            #expect(request.value(forHTTPHeaderField: own.name) == own.value, "a request to the target lost its own header")
            #expect(request.value(forHTTPHeaderField: theirs.name) == nil, "a request to the target carries the other server's secret")
        }
    }

    @Test("One key: two spellings of a server are one entry, and both read the same rows")
    func twoSpellingsAreOneEntry() throws {
        let keys = Keys()
        let host = "music-\(UUID().uuidString.prefix(6).lowercased()).example.com"
        let upper = try #require(URL(string: "https://\(host.uppercased())"))
        let spelled = try #require(URL(string: "https://\(host):443/"))
        let first = ServerHeaderRule.Header(name: ServerHeadersWayTests.name, value: "a")
        let second = ServerHeaderRule.Header(name: ServerHeadersWayTests.name, value: "b")
        #expect(ServerHeaderRule.key(upper) == "https://\(host)")
        #expect(ServerHeaderRule.key(spelled) == "https://\(host)")
        #expect(ServerHeaderRule.key(try #require(URL(string: "http://\(host):8080/abs/"))) == "http://\(host):8080/abs")
        #expect(ServerHeaderRule.key(try #require(URL(string: "https://name:secret@\(host)"))) == "https://\(host)")
        ServerHeaders.$witness.withValue(keys.keys()) {
            ServerHeaders.set([first], for: upper)
            #expect(ServerHeaders.stored(for: spelled) == [first], "the other spelling reads empty over a header in force")
            ServerHeaders.set([second], for: spelled)
            #expect(ServerHeaders.stored(for: upper) == [second])
        }
        #expect(keys.state.withLock { $0.items.count } == 1, "two spellings made two entries")
        #expect(keys.state.withLock { $0.bases } == ["https://\(host)"])
    }

    @Test("One key: an entry under an old spelling is lifted once on the first read, of two the one under the key stays")
    func oldSpellingsAreLiftedOnce() throws {
        let host = "abs-\(UUID().uuidString.prefix(6).lowercased()).example"
        let prefix = ServerHeaders.accountPrefix
        func json(_ value: String) -> String { #"[{"name":"X-Gate","value":"\#(value)"}]"# }
        // One old spelling alone: lifted onto the key, nothing left behind.
        let alone = Keys(.init(items: [prefix + "https://\(host.uppercased()):443": json("old")]))
        try ServerHeaders.$witness.withValue(alone.keys()) {
            let entries = try #require(ServerHeaders.entries())
            #expect(entries.count == 1)
            #expect(ServerHeaders.stored(for: try #require(URL(string: "https://\(host)"))) == [.init(name: "X-Gate", value: "old")])
        }
        #expect(alone.state.withLock { $0.items } == [prefix + "https://\(host)": json("old")])
        // A second read writes nothing more.
        #expect(ServerHeaders.lifted(alone.state.withLock { $0.items }).writes.isEmpty)
        // Two spellings of one server: the one under the key stays in the
        // table, the other stays in the keychain under its own account.
        let both = Keys(.init(items: [prefix + "https://\(host)": json("kept"),
                                      prefix + "https://\(host)/": json("left")]))
        let table = ServerHeaders.$witness.withValue(both.keys()) { ServerHeaders.entries() }
        #expect(table?.map(\.headers) == [[.init(name: "X-Gate", value: "kept")]])
        #expect(both.state.withLock { $0.items } == [prefix + "https://\(host)": json("kept"),
                                                     prefix + "https://\(host)/": json("left")],
                "a spelling left out of the table was removed from the keychain")
    }

    @Test("One key: of two old spellings with no entry under the key, the one the register names is lifted, not the first")
    func theRegisteredSpellingIsLifted() throws {
        let host = "gate-\(UUID().uuidString.prefix(6).lowercased()).example"
        let prefix = ServerHeaders.accountPrefix
        func json(_ value: String) -> String { #"[{"name":"X-Gate","value":"\#(value)"}]"# }
        let first = "https://\(host.uppercased())"
        let named = "https://\(host)/"
        let keys = Keys(.init(items: [prefix + first: json("older"), prefix + named: json("in force")],
                              bases: [named]))
        let base = try #require(URL(string: "https://\(host)"))
        let stored = ServerHeaders.$witness.withValue(keys.keys()) { ServerHeaders.stored(for: base) }
        #expect(stored == [.init(name: "X-Gate", value: "in force")],
                "the first spelling in order was lifted over the one the register names")
        #expect(keys.state.withLock { $0.items } == [prefix + "https://\(host)": json("in force"), prefix + first: json("older")])
        // Without a register the first in order is lifted.
        let plain = ServerHeaders.lifted([prefix + first: json("older"), prefix + named: json("in force")])
        #expect(plain.items == [prefix + "https://\(host)": json("older")])
        #expect(plain.dropped == 1)
    }

    @Test("One key: an IPv6 server and an encoded path read back as the same key")
    func theKeyReadsBack() throws {
        for raw in ["https://[fd00::1]:8443/abs/", "https://[::1]/my%20abs", "HTTPS://Demo.Example:443/", "http://x.example:80/a/b//"] {
            let address = try #require(URL(string: raw))
            let key = try #require(ServerHeaderRule.key(address), "\(raw) has no key")
            let back = try #require(URL(string: key), "the key \(key) does not read as an address")
            #expect(ServerHeaderRule.key(back) == key, "\(raw) does not read back")
        }
        #expect(ServerHeaderRule.key(try #require(URL(string: "https://[FD00::1]:8443/abs"))) == "https://[fd00::1]:8443/abs")
        // A server under IPv6 keeps its headers through a read.
        let keys = Keys()
        let base = try #require(URL(string: "https://[fd00::1]:8443/abs"))
        let header = ServerHeaderRule.Header(name: "X-Gate", value: "v6")
        ServerHeaders.$witness.withValue(keys.keys()) {
            #expect(ServerHeaders.set([header], for: base))
            #expect(ServerHeaders.stored(for: base) == [header], "the headers of an IPv6 server read empty")
        }
    }

    @Test("Saving: when the keychain takes nothing, set says no and the register stays; a move over an unreadable one is not taken")
    func aWriteNotTakenSaysSo() throws {
        let keys = Keys(.init(takes: false))
        let base = try #require(URL(string: "https://refused-\(UUID().uuidString.prefix(6).lowercased()).example"))
        let other = try #require(URL(string: "https://other-\(UUID().uuidString.prefix(6).lowercased()).example"))
        ServerHeaders.$witness.withValue(keys.keys()) {
            #expect(!ServerHeaders.set([.init(name: "X-Gate", value: "a")], for: base), "a write the keychain did not take said yes")
        }
        #expect(keys.state.withLock { $0.bases }.isEmpty, "the register names a server whose headers were not kept")
        let locked = Keys(.init(readable: false))
        ServerHeaders.$witness.withValue(locked.keys()) {
            #expect(ServerHeaders.move(from: base, to: other) == .notTaken)
        }
    }

    @Test("Saving: the sheet says when the headers are not saved, and keeps the address before them", .needsTheSources)
    func theSectionSaysWhenNotKept() throws {
        let section = try FetchAnswerTests.squeezedSource("Sources/Views/CustomHeadersSection.swift")
        #expect(section.contains("case .notTaken: notKept = true return"), "a move not taken passes in silence")
        #expect(section.contains("guard ServerHeaders.set(headers, for: base) else { notKept = true"), "a set not taken passes in silence")
        #expect(section.contains("if notKept { Text(\"The headers could not be saved."), "the sheet does not say it")
        let store = try FetchAnswerTests.squeezedSource("Sources/Networking/ServerHeaders.swift")
        #expect(store.contains("SERVERHEADERS headers not kept"), "set does not write a line when it is not taken")
        #expect(store.contains("SERVERHEADERS not moved host=\\(new.host ?? \"-\", privacy: .public): the keychain cannot be read"))
    }

    @Test("Reading: unreadable is not empty")
    func unreadableIsNotEmpty() throws {
        let keys = Keys(.init(readable: false))
        let base = try #require(URL(string: "https://locked.example"))
        ServerHeaders.$witness.withValue(keys.keys()) {
            #expect(ServerHeaders.stored(for: base) == nil)
        }
    }

    @Test("Guard: an answer from another host or 401/403 as a web page is a guard, the answer of the server is not")
    func theGuardRule() throws {
        let server = try #require(URL(string: "https://music.example.com/rest/ping"))
        let login = try #require(URL(string: "https://team.cloudflareaccess.com/cdn-cgi/access/login"))
        #expect(AccessGuard.standsAhead(requested: server, final: login, status: 200, contentType: "text/html"))
        #expect(AccessGuard.standsAhead(requested: server, final: server, status: 403, contentType: "text/html; charset=utf-8"))
        #expect(AccessGuard.standsAhead(requested: server, final: server, status: 401, contentType: "text/html"))
        #expect(!AccessGuard.standsAhead(requested: server, final: server, status: 401, contentType: "application/json"),
                "the server's own refusal is no guard")
        #expect(!AccessGuard.standsAhead(requested: server, final: server, status: 200, contentType: "text/html"))
        #expect(!AccessGuard.standsAhead(requested: server, final: nil, status: nil, contentType: nil))
    }

    @Test("Guard: a server whose address redirects to another host gets the sentence; one that answers itself keeps its own")
    func theGuardSentenceAtTheLoopback() async throws {
        let body = try HeaderRedirectMeasureTests.tone()
        let guarded = try Host(body: body, contentType: "text/html")
        let login = try Host(body: body, contentType: "text/html")
        try await guarded.start()
        try await login.start()
        defer { guarded.stop(); login.stop() }
        guarded.redirect(to: try #require(URL(string: "http://localhost:\(login.port)/login")))
        guarded.redirecting.withLock { $0 = "/start" }
        let own = "Server not reachable."
        let guardedAnswer = await ServerHeaders.$witness.withValue(Keys().keys()) {
            await AccessGuard.sentence(after: own, address: "http://127.0.0.1:\(guarded.port)/start")
        }
        #expect(guardedAnswer == String(localized: "A sign-in stands in front of the server (Cloudflare Access, for example). Enter what it asks for under Custom Headers."))
        let plainAnswer = await ServerHeaders.$witness.withValue(Keys().keys()) {
            await AccessGuard.sentence(after: own, address: "http://127.0.0.1:\(login.port)/rest")
        }
        #expect(plainAnswer == own, "a server answering itself got the guard's sentence")
    }
}

/// Every server sheet carries the one component, and every connection
/// check of a sheet asks the one guard.
struct CustomHeadersFenceTests {
    static let sheets = ["SetupView.swift", "SubsonicSourceView.swift", "JellyfinSourceView.swift",
                         "GPodderSettingsView.swift", "PodcastSourceView.swift", "MaerSyncSettingsView.swift"]

    @Test("Custom headers: every server sheet carries the one component, the sheet of a feed does not", .needsTheSources)
    func everyServerSheetCarriesTheSection() {
        var carriers: [String: Int] = [:]
        var forms: [String: Int] = [:]
        for (file, text) in ProjectFileIntegrityTests.sourceTexts() {
            let code = SyncContractFenceTests.stripped(text)
            let section = code.components(separatedBy: "CustomHeadersSection(address:").count - 1
            if section > 0 { carriers[file] = section }
            let server = code.components(separatedBy: "CredentialField.serverURL(").count - 1
                - code.components(separatedBy: "CredentialField.serverURL(\"Feed URL\"").count + 1
            if server > 0 { forms[file] = server }
        }
        #expect(carriers == Dictionary(uniqueKeysWithValues: Self.sheets.map { ($0, 1) }), "the carriers: \(carriers)")
        #expect(Set(forms.keys) == Set(Self.sheets), "a server form without the headers: \(forms)")
    }

    @Test("Custom headers: every connection check of the six sheets asks the one guard", .needsTheSources)
    func everyCheckAsksTheGuard() {
        var askers: Set<String> = []
        for (file, text) in ProjectFileIntegrityTests.sourceTexts()
        where SyncContractFenceTests.stripped(text).contains("AccessGuard.sentence(after:") {
            askers.insert(file)
        }
        #expect(askers == ["AuthViewModel.swift", "SubsonicSourceView.swift", "JellyfinSourceView.swift",
                           "GPodderSettingsView.swift", "PodcastSourceView.swift", "MaerSyncSettingsView.swift"],
                "the askers: \(askers.sorted())")
    }
}
#endif
