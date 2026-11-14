// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Every status line the contract fixes the app to, driven at its edge,
/// without a service. Until now the translation lived inside the door and
/// no witness named it: a 412 translated as `written` left the whole suite
/// green, while a carrier empties its queue on `written`. Two cases here
/// carry that finding on their own; the rest hold the table.
struct MaerSyncAnswerTests {
    private func failure(_ body: () throws -> Any) -> MaerSyncFailure? {
        do { _ = try body(); return nil } catch { return error as? MaerSyncFailure }
    }

    // MARK: - The two that carry the finding

    @Test("412 is NEVER written: a rejected write stays in the queue")
    func aRefusedWriteIsNeverWritten() throws {
        let stale = try MaerSyncAnswer.written(MaerSyncReply(status: 412, etag: "7"))
        #expect(stale == .stale(current: "7"))
        // And without the service naming the version it holds, still stale,
        // with nothing to compare against.
        #expect(try MaerSyncAnswer.written(MaerSyncReply(status: 412)) == .stale(current: nil))
        if case .written = stale { Issue.record("a 412 came back as written") }
    }

    @Test("404 is not an error but means not there yet: the first round of every device")
    func notFoundIsNotThereYet() throws {
        #expect(try MaerSyncAnswer.document(MaerSyncReply(status: 404)) == nil)
        #expect(failure { try MaerSyncAnswer.document(MaerSyncReply(status: 404)) } == nil, "no throw")
    }

    // MARK: - The table, way by way

    @Test("fetch: document with ETag and version, otherwise unreadable; 401 halts; everything else is its status")
    func fetchTranslations() throws {
        let body = Data("pot".utf8)
        let document = try MaerSyncAnswer.document(MaerSyncReply(status: 200, etag: "3", format: "1", body: body))
        #expect(document == MaerSyncDocument(body: body, format: 1, etag: "3"))
        #expect(failure { try MaerSyncAnswer.document(MaerSyncReply(status: 200, format: "1")) } == .unreadable, "no etag")
        #expect(failure { try MaerSyncAnswer.document(MaerSyncReply(status: 200, etag: "3")) } == .unreadable, "no format")
        #expect(failure { try MaerSyncAnswer.document(MaerSyncReply(status: 200, etag: "3", format: "one")) } == .unreadable)
        #expect(failure { try MaerSyncAnswer.document(MaerSyncReply(status: 401)) } == .unauthorized)
        #expect(failure { try MaerSyncAnswer.document(MaerSyncReply(status: 500)) } == .status(500))
        #expect(failure { try MaerSyncAnswer.document(MaerSyncReply(status: 403)) } == .status(403))
    }

    @Test("write: written with ETag, otherwise unreadable; 409 carries the service's sentence; 401; otherwise status")
    func writeTranslations() throws {
        #expect(try MaerSyncAnswer.written(MaerSyncReply(status: 200, etag: "4")) == .written(etag: "4"))
        #expect(failure { try MaerSyncAnswer.written(MaerSyncReply(status: 200)) } == .unreadable, "written without a version is no write")
        let refused = try MaerSyncAnswer.written(MaerSyncReply(status: 409, body: Data("{\"reason\": \"shrank below the floor\"}".utf8)))
        #expect(refused == .refused(reason: "shrank below the floor"))
        #expect(try MaerSyncAnswer.written(MaerSyncReply(status: 409)) == .refused(reason: "refused"), "a body without a sentence gets the bare word")
        #expect(failure { try MaerSyncAnswer.written(MaerSyncReply(status: 401)) } == .unauthorized)
        #expect(failure { try MaerSyncAnswer.written(MaerSyncReply(status: 413)) } == .status(413))
        #expect(failure { try MaerSyncAnswer.written(MaerSyncReply(status: 404)) } == .status(404), "a write has no such document to be missing")
    }

    @Test("list: the entries, an unreadable body is unreadable; 401; otherwise status")
    func listTranslations() throws {
        let body = Data("{\"documents\": [{\"scope\": \"b\", \"version\": \"2\", \"format\": 1}, {\"scope\": \"a\", \"version\": \"9\", \"format\": 2}]}".utf8)
        let listed = try MaerSyncAnswer.listing(MaerSyncReply(status: 200, body: body))
        #expect(listed == [MaerSyncListed(scope: "b", etag: "2", format: 1), MaerSyncListed(scope: "a", etag: "9", format: 2)])
        #expect(try MaerSyncAnswer.listing(MaerSyncReply(status: 200, body: Data("{\"documents\": []}".utf8))) == [])
        #expect(failure { try MaerSyncAnswer.listing(MaerSyncReply(status: 200, body: Data("nonsense".utf8))) } == .unreadable)
        #expect(failure { try MaerSyncAnswer.listing(MaerSyncReply(status: 401)) } == .unauthorized)
        #expect(failure { try MaerSyncAnswer.listing(MaerSyncReply(status: 502)) } == .status(502))
    }

    @Test("token: the token, an empty one is none; 401; otherwise status")
    func tokenTranslations() throws {
        #expect(try MaerSyncAnswer.token(MaerSyncReply(status: 200, body: Data("{\"token\": \"t-1\"}".utf8))) == "t-1")
        #expect(failure { try MaerSyncAnswer.token(MaerSyncReply(status: 200, body: Data("{\"token\": \"\"}".utf8))) } == .unreadable)
        #expect(failure { try MaerSyncAnswer.token(MaerSyncReply(status: 200, body: Data("{}".utf8))) } == .unreadable)
        #expect(failure { try MaerSyncAnswer.token(MaerSyncReply(status: 401)) } == .unauthorized)
        #expect(failure { try MaerSyncAnswer.token(MaerSyncReply(status: 403)) } == .status(403))
    }

    private func keyBody(_ raw: Data, label: String) -> Data {
        Data("{\"key\": \"\(raw.base64EncodedString())\", \"fingerprint\": \"\(label)\"}".utf8)
    }

    @Test("key: the fingerprint is computed from the bytes, the label is only a cross-check, 31 bytes are no key")
    func keyTranslations() throws {
        let raw = Data(repeating: 7, count: 32)
        let key = try MaerSyncAnswer.serviceKey(MaerSyncReply(status: 200, body: keyBody(raw, label: "9ER6-Z3JE-79VH-BMG1-TNSX-1AJ2")))
        #expect(key.key == raw && key.fingerprint == "9ER6-Z3JE-79VH-BMG1-TNSX-1AJ2")
        // A label that does not belong to the bytes is not "a different
        // key": it is an answer that does not hold together.
        #expect(failure { try MaerSyncAnswer.serviceKey(MaerSyncReply(status: 200, body: keyBody(raw, label: "CC6W-TAB6-RGSP-D48J-AH4B-QCJV"))) } == .unreadable,
                "somebody else's label over these bytes")
        // And the other way round: somebody else's bytes under the old
        // label, which is what a man in the middle would send.
        let otherBytes = Data(0..<32)
        #expect(failure { try MaerSyncAnswer.serviceKey(MaerSyncReply(status: 200, body: keyBody(otherBytes, label: "9ER6-Z3JE-79VH-BMG1-TNSX-1AJ2"))) } == .unreadable,
                "the old label over other bytes")
        #expect(failure { try MaerSyncAnswer.serviceKey(MaerSyncReply(status: 200, body: keyBody(Data(repeating: 7, count: 31), label: "9ER6"))) } == .unreadable,
                "31 bytes are not a key")
        #expect(failure { try MaerSyncAnswer.serviceKey(MaerSyncReply(status: 404)) } == .serviceIsOlder,
                "an older service, by its name here, so the sign-in AND the rounds read it (GT-20)")
    }

    @Test("503 means that the service has no key only with the service's sentence; without the sentence it is the number of something else")
    func fiveOhThreeHasOneMeaningOnlyWithItsSentence() throws {
        let itsOwn = Data("{\"reason\": \"this service has no static key\"}".utf8)
        #expect(failure { try MaerSyncAnswer.serviceKey(MaerSyncReply(status: 503, body: itsOwn)) } == .serviceHasNoKey)
        #expect(failure { try MaerSyncAnswer.session(MaerSyncReply(status: 503, body: itsOwn)) } == .serviceHasNoKey)
        // A proxy under load or in maintenance answers 503 too, with an
        // empty body or its own page; that is not "no key yet", and telling
        // the person to go and make a key would send them to the wrong end.
        #expect(failure { try MaerSyncAnswer.serviceKey(MaerSyncReply(status: 503)) } == .status(503))
        #expect(failure { try MaerSyncAnswer.session(MaerSyncReply(status: 503, body: Data("<html>maintenance</html>".utf8))) } == .status(503))

        let session = try MaerSyncAnswer.session(MaerSyncReply(status: 200, session: "s-1", body: Data([1, 2, 3])))
        #expect(session.session == "s-1" && session.reply == Data([1, 2, 3]))
        #expect(failure { try MaerSyncAnswer.session(MaerSyncReply(status: 200, body: Data([1]))) } == .unreadable, "no name, no session")
        #expect(failure { try MaerSyncAnswer.session(MaerSyncReply(status: 400)) } == .status(400))
    }

    @Test("on the outside only the session speaks: 200 is the sealed bytes, 410 is ended, 400 does not open")
    func theOuterAnswerSpeaksOnlyAboutTheSession() throws {
        #expect(try MaerSyncAnswer.tunnel(MaerSyncReply(status: 200, body: Data([1, 2]))) == Data([1, 2]))
        #expect(failure { try MaerSyncAnswer.tunnel(MaerSyncReply(status: 410)) } == .sessionEnded)
        #expect(failure { try MaerSyncAnswer.tunnel(MaerSyncReply(status: 400)) } == .unreadable)
        #expect(failure { try MaerSyncAnswer.tunnel(MaerSyncReply(status: 503, body: Data("{\"reason\": \"this service has no static key\"}".utf8))) } == .serviceHasNoKey)
        #expect(failure { try MaerSyncAnswer.tunnel(MaerSyncReply(status: 503)) } == .status(503))
        // The inner 401 is INSIDE the bytes and never here: an outer 401 is
        // something in front of the service and stays a number.
        #expect(failure { try MaerSyncAnswer.tunnel(MaerSyncReply(status: 401)) } == .status(401))
    }

    @Test("an answer is built from the three named headers, otherwise from nothing")
    func aReplyReadsTheNamedHeaders() throws {
        let response = try #require(HTTPURLResponse(url: URL(string: "https://sync.example.test/v1/doc/stands")!,
                                                     statusCode: 200, httpVersion: nil,
                                                     headerFields: ["ETag": "5", "X-Maer-Format": "2", "X-Maer-Session": "n"]))
        let reply = MaerSyncReply(response, body: Data("x".utf8))
        #expect(reply.status == 200 && reply.etag == "5" && reply.format == "2" && reply.session == "n")
        #expect(reply.body == Data("x".utf8))
        let bareResponse = try #require(HTTPURLResponse(url: URL(string: "https://sync.example.test")!,
                                                        statusCode: 412, httpVersion: nil, headerFields: nil))
        let bare = MaerSyncReply(bareResponse, body: Data())
        #expect(bare.etag == nil && bare.format == nil && bare.session == nil)
    }

    // MARK: - The fence

    /// The door fetches bytes and hands them in; it compares no status
    /// itself. Otherwise a second translation grows in the shell, untested,
    /// which is exactly where the 412 lived until this file existed. The
    /// one number the door passes on is the health route's, and it passes
    /// it on as a number, not as a decision.
    @Test("the door compares no status; the translation lives in one place", .needsTheSources)
    func theDoorComparesNoStatus() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let whole = try String(contentsOf: root.appendingPathComponent("Sources/Networking/MaerSyncClient.swift"),
                               encoding: .utf8)
        let start = try #require(whole.range(of: "final class MaerSyncHTTP"))
        let end = whole.range(of: "final class MaerSyncSocket") ?? whole.endIndex..<whole.endIndex
        let door = SyncContractFenceTests.stripped(String(whole[start.upperBound..<end.lowerBound]))
        #expect(!door.contains("switch response.statusCode"), "the door switches on a status")
        #expect(!door.contains("statusCode =="), "the door compares a status")
        #expect(door.range(of: "case [0-9]{3}", options: .regularExpression) == nil, "the door names a status")
        #expect(door.contains("MaerSyncAnswer."), "the door hands its answers to the translation at all")
        // Every way its OWN translation, not one call somewhere: a door
        // that translated three ways and answered the fourth by hand would
        // have passed the line above. Named limit of the first version,
        // found by a null probe from the other side.
        for way in ["document(", "written(", "listing(", "token(", "serviceKey("] {
            #expect(door.contains("MaerSyncAnswer.\(way)"), "the door does not hand \(way) to the translation")
        }
        // The counter direction: the translation exists and carries the
        // statuses the contract fixes, so this case cannot pass over a door
        // that simply stopped answering.
        let translation = SyncContractFenceTests.stripped(String(whole[..<start.lowerBound]))
        for status in ["200", "401", "404", "409", "412", "503"] {
            #expect(translation.contains("case \(status)"), "\(status) is translated somewhere")
        }
    }
}
#endif
