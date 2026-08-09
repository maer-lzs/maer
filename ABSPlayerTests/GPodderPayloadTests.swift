// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import ABSPlayer

/// Fix 01.08 (bestätigter Befund): a 2xx response with an unreadable body
/// must THROW instead of silently becoming "0 subscriptions" — a captive
/// portal in a foreign WLAN must never look like an emptied subscription
/// list. The REAL empty list stays valid (and still runs into the
/// mass-delete guard as the second line of defense).
struct GPodderPayloadTests {

    // MARK: - Unreadable 2xx bodies → badPayload (the reported failure class)

    @Test("captive-portal HTML throws instead of decaying to []")
    func htmlBodyThrows() {
        let html = Data("<html><head><title>WLAN Login</title></head><body>…</body></html>".utf8)
        #expect(throws: GPodderError.self) { try GPodderClient.parseSubscriptions(html) }
    }

    @Test("empty body throws")
    func emptyBodyThrows() {
        #expect(throws: GPodderError.self) { try GPodderClient.parseSubscriptions(Data()) }
    }

    @Test("foreign JSON throws")
    func foreignJSONThrows() {
        let foreign = Data(#"{"error":"login required"}"#.utf8)
        #expect(throws: GPodderError.self) { try GPodderClient.parseSubscriptions(foreign) }
    }

    @Test("devices: non-array body throws")
    func devicesBadBodyThrows() {
        #expect(throws: GPodderError.self) {
            _ = try GPodderClient.parseDevices(Data("<html>proxy</html>".utf8))
        }
    }

    // MARK: - Valid forms keep working (incl. the REAL empty list)

    @Test("plain string array parses")
    func plainArrayParses() throws {
        let data = Data(#"["https://a.example/feed.xml","https://b.example/feed.xml"]"#.utf8)
        #expect(try GPodderClient.parseSubscriptions(data).count == 2)
    }

    @Test("change format parses (add wins)")
    func changeFormatParses() throws {
        let data = Data(#"{"add":["https://a.example/feed.xml"],"remove":[],"timestamp":7}"#.utf8)
        #expect(try GPodderClient.parseSubscriptions(data) == ["https://a.example/feed.xml"])
    }

    @Test("the REAL empty list stays valid — guard handles it, not badPayload")
    func realEmptyListStaysValid() throws {
        #expect(try GPodderClient.parseSubscriptions(Data("[]".utf8)).isEmpty)
        let changes = Data(#"{"add":[],"remove":[],"timestamp":7}"#.utf8)
        #expect(try GPodderClient.parseSubscriptions(changes).isEmpty)
    }

    @Test("devices: valid array parses")
    func devicesValidParses() throws {
        let data = Data(#"[{"id":"maer-1","caption":"Maer"}]"#.utf8)
        #expect(try GPodderClient.parseDevices(data).count == 1)
    }
}
#endif
