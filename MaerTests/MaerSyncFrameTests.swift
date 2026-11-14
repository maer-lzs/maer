// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The frame inside a session, at its edges, and against two frames the
/// service's own function produced: two constructions of one shape in two
/// languages are only known to agree by fixed bytes.
struct MaerSyncFrameTests {
    /// `core.frames.pack(...)` in the service repository, 2026-09-17.
    static let requestVector = Data(hex: "00587b2268656164657273223a7b22417574686f72697a6174696f6e223a224265617265722074227d2c226d6574686f64223a22474554222c22746172676574223a222f76312f646f632f7374616e64733f73636f70653d227d78")
    static let replyVector = Data(hex: "00397b2268656164657273223a7b2265746167223a2233222c22782d6d6165722d666f726d6174223a2231227d2c22737461747573223a3230307d7b226b223a2276227d")

    @Test("a request frame is byte for byte the service's")
    func aRequestFramePacksToTheServicesBytes() throws {
        let head = MaerSyncFrame.requestHead(method: "GET", target: "/v1/doc/stands?scope=",
                                             headers: ["Authorization": "Bearer t"])
        #expect(try MaerSyncFrame.pack(head: head, body: Data("x".utf8)) == Self.requestVector)
    }

    @Test("a response frame of the service opens here, status, headers and body")
    func aReplyFrameFromTheServiceUnpacks() throws {
        let (head, body) = try MaerSyncFrame.unpack(Self.replyVector)
        let (status, headers) = try MaerSyncFrame.reply(of: head)
        #expect(status == 200)
        #expect(headers == ["etag": "3", "x-maer-format": "1"])
        #expect(body == Data("{\"k\":\"v\"}".utf8))
    }

    @Test("the body travels raw, and a frame from a concatenation opens")
    func theBodyIsRawAndConcatenatedFramesUnpack() throws {
        let raw = Data((0...255).map { UInt8($0) })
        let frame = try MaerSyncFrame.pack(head: ["status": 200, "headers": [:]], body: raw)
        // A Data made by appending does not start at index zero; the
        // unpacking must not assume it does.
        let shifted = Data([9, 9]).dropFirst(2) + frame
        let (_, body) = try MaerSyncFrame.unpack(Data(shifted))
        #expect(body == raw)
        #expect(try MaerSyncFrame.unpack(try MaerSyncFrame.pack(head: ["status": 200, "headers": [:]], body: Data())).body == Data())
    }

    @Test("header names arrive in lower case, as from a wire")
    func headerNamesArriveLowercased() throws {
        let (status, headers) = try MaerSyncFrame.reply(of: ["status": 412, "headers": ["ETag": "7"]])
        #expect(status == 412 && headers == ["etag": "7"])
    }

    @Test("what is no frame is unreadable, and a head without status too")
    func whatIsNotAFrameIsUnreadable() {
        for wrong in [Data(), Data([0]), Data([0, 5, 97, 98]), Data([0, 2, 91, 93]), Data([0, 3, 97, 98, 99])] {
            #expect(throws: MaerSyncFailure.unreadable) { try MaerSyncFrame.unpack(wrong) }
        }
        #expect(throws: MaerSyncFailure.unreadable) { try MaerSyncFrame.reply(of: ["status": "200"]) }
        #expect(throws: MaerSyncFailure.unreadable) { try MaerSyncFrame.reply(of: ["status": 99, "headers": [:]]) }
        #expect(throws: MaerSyncFailure.unreadable) { try MaerSyncFrame.reply(of: ["status": 200, "headers": ["a": 1]]) }
    }

    @Test("the target of an address is path and query, like a request line")
    func theTargetOfAnAddress() {
        let base = URL(string: "https://sync.example.test")!
        #expect(MaerSyncFrame.target(of: MaerSyncPaths.document(base, kind: "claim", scope: "dev:a")) == "/v1/doc/claim?scope=dev:a")
        #expect(MaerSyncFrame.target(of: MaerSyncPaths.document(base, kind: "stands", scope: "")) == "/v1/doc/stands")
        #expect(MaerSyncFrame.target(of: MaerSyncPaths.token(base)) == "/v1/token")
        #expect(MaerSyncFrame.target(of: base) == "/")
    }
}

extension Data {
    /// Bytes out of a hex string, for vectors that were printed by another
    /// language. A string that is not hex gives an empty Data, which no
    /// vector above is, so a typo tears at the comparison.
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            guard let byte = UInt8(hex[index..<next], radix: 16) else { self.init(); return }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
#endif
