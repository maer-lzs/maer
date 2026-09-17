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

    @Test("412 ist NIEMALS written: ein abgewiesener Schrieb bleibt in der Warteschlange")
    func aRefusedWriteIsNeverWritten() throws {
        let stale = try MaerSyncAnswer.written(MaerSyncReply(status: 412, etag: "7"))
        #expect(stale == .stale(current: "7"))
        // And without the service naming the version it holds, still stale,
        // with nothing to compare against.
        #expect(try MaerSyncAnswer.written(MaerSyncReply(status: 412)) == .stale(current: nil))
        if case .written = stale { Issue.record("a 412 came back as written") }
    }

    @Test("404 ist kein Fehler, sondern gibt es noch nicht: die erste Runde jedes Geraets")
    func notFoundIsNotThereYet() throws {
        #expect(try MaerSyncAnswer.document(MaerSyncReply(status: 404)) == nil)
        #expect(failure { try MaerSyncAnswer.document(MaerSyncReply(status: 404)) } == nil, "no throw")
    }

    // MARK: - The table, way by way

    @Test("fetch: Dokument mit ETag und Fassung, sonst unlesbar; 401 haelt an; alles andere ist sein Status")
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

    @Test("write: written mit ETag, sonst unlesbar; 409 traegt den Satz des Dienstes; 401; sonst Status")
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

    @Test("list: die Eintraege, ein unlesbarer Rumpf ist unlesbar; 401; sonst Status")
    func listTranslations() throws {
        let body = Data("{\"documents\": [{\"scope\": \"b\", \"version\": \"2\", \"format\": 1}, {\"scope\": \"a\", \"version\": \"9\", \"format\": 2}]}".utf8)
        let listed = try MaerSyncAnswer.listing(MaerSyncReply(status: 200, body: body))
        #expect(listed == [MaerSyncListed(scope: "b", etag: "2", format: 1), MaerSyncListed(scope: "a", etag: "9", format: 2)])
        #expect(try MaerSyncAnswer.listing(MaerSyncReply(status: 200, body: Data("{\"documents\": []}".utf8))) == [])
        #expect(failure { try MaerSyncAnswer.listing(MaerSyncReply(status: 200, body: Data("nonsense".utf8))) } == .unreadable)
        #expect(failure { try MaerSyncAnswer.listing(MaerSyncReply(status: 401)) } == .unauthorized)
        #expect(failure { try MaerSyncAnswer.listing(MaerSyncReply(status: 502)) } == .status(502))
    }

    @Test("token: das Zeichen, ein leeres ist keins; 401; sonst Status")
    func tokenTranslations() throws {
        #expect(try MaerSyncAnswer.token(MaerSyncReply(status: 200, body: Data("{\"token\": \"t-1\"}".utf8))) == "t-1")
        #expect(failure { try MaerSyncAnswer.token(MaerSyncReply(status: 200, body: Data("{\"token\": \"\"}".utf8))) } == .unreadable)
        #expect(failure { try MaerSyncAnswer.token(MaerSyncReply(status: 200, body: Data("{}".utf8))) } == .unreadable)
        #expect(failure { try MaerSyncAnswer.token(MaerSyncReply(status: 401)) } == .unauthorized)
        #expect(failure { try MaerSyncAnswer.token(MaerSyncReply(status: 403)) } == .status(403))
    }

    @Test("key und session: 503 hat seinen Namen, ein Schluessel hat 32 Byte, eine Sitzung hat einen Namen")
    func keyAndSessionTranslations() throws {
        let raw = Data(repeating: 9, count: 32)
        let good = Data("{\"key\": \"\(raw.base64EncodedString())\", \"fingerprint\": \"AAAA-BBBB\"}".utf8)
        let key = try MaerSyncAnswer.serviceKey(MaerSyncReply(status: 200, body: good))
        #expect(key.key == raw && key.fingerprint == "AAAA-BBBB")
        let short = Data("{\"key\": \"\(Data(repeating: 9, count: 31).base64EncodedString())\", \"fingerprint\": \"AAAA\"}".utf8)
        #expect(failure { try MaerSyncAnswer.serviceKey(MaerSyncReply(status: 200, body: short)) } == .unreadable, "31 bytes are not a key")
        #expect(failure { try MaerSyncAnswer.serviceKey(MaerSyncReply(status: 503)) } == .serviceHasNoKey)
        #expect(failure { try MaerSyncAnswer.serviceKey(MaerSyncReply(status: 404)) } == .status(404), "an older service, by its number; the sign-in names it")

        let session = try MaerSyncAnswer.session(MaerSyncReply(status: 200, session: "s-1", body: Data([1, 2, 3])))
        #expect(session.session == "s-1" && session.reply == Data([1, 2, 3]))
        #expect(failure { try MaerSyncAnswer.session(MaerSyncReply(status: 200, body: Data([1]))) } == .unreadable, "no name, no session")
        #expect(failure { try MaerSyncAnswer.session(MaerSyncReply(status: 503)) } == .serviceHasNoKey)
        #expect(failure { try MaerSyncAnswer.session(MaerSyncReply(status: 400)) } == .status(400))
    }

    @Test("eine Antwort wird aus den drei benannten Koepfen gebaut, sonst aus nichts")
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
    @Test("die Tuer vergleicht keinen Status; die Uebersetzung steht an einer Stelle")
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
