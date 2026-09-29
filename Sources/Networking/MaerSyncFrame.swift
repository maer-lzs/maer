// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The shape of what travels INSIDE a session, pure.
///
/// A sealed request is one ordinary request of the service, whole: method,
/// target, headers and body, so the wire inside the session is exactly the
/// wire the contract already describes. A sealed reply is one ordinary
/// reply: status, headers and body. Two bytes of length, big endian, then a
/// small JSON head, then the raw body; the body is not put through JSON
/// because documents are the bulk of the traffic and base64 would make each
/// a third larger. Same construction as `core/frames.py` in the service,
/// held to it by fixed vectors in the witnesses.
///
/// Nothing here encrypts; the session does that around the frame.
nonisolated enum MaerSyncFrame {
    static let lengthBytes = 2

    /// A frame from a head and a body. The head is written with sorted keys
    /// and without spaces, as the service writes it, and without escaping
    /// slashes, because a target is full of them and the service does not
    /// escape them either.
    static func pack(head: [String: Any], body: Data) throws -> Data {
        guard JSONSerialization.isValidJSONObject(head) else { throw MaerSyncFailure.unreadable }
        let encoded = try JSONSerialization.data(withJSONObject: head, options: [.sortedKeys, .withoutEscapingSlashes])
        guard encoded.count <= 0xFFFF else { throw MaerSyncFailure.unreadable }
        var out = Data([UInt8(encoded.count >> 8), UInt8(encoded.count & 0xFF)])
        out.append(encoded)
        out.append(body)
        return out
    }

    /// The head and the body out of a frame. Indexed from `startIndex` on
    /// purpose: a `Data` that came out of a concatenation does not start at
    /// zero, and `frame[0]` on one of those traps.
    static func unpack(_ frame: Data) throws -> (head: [String: Any], body: Data) {
        guard frame.count >= lengthBytes else { throw MaerSyncFailure.unreadable }
        let lengthField = frame.prefix(lengthBytes)
        let length = Int(lengthField[lengthField.startIndex]) << 8 | Int(lengthField[lengthField.startIndex + 1])
        let rest = frame.dropFirst(lengthBytes)
        guard rest.count >= length else { throw MaerSyncFailure.unreadable }
        let headBytes = Data(rest.prefix(length))
        // bearable, because an unreadable header is thrown as unreadable right below; the reason travels on as an error
        guard let head = (try? JSONSerialization.jsonObject(with: headBytes)) as? [String: Any]
        else { throw MaerSyncFailure.unreadable }
        return (head, Data(rest.dropFirst(length)))
    }

    /// The head of a request: what a server reads off a request line, plus
    /// the headers. The target carries the query, as a request line does.
    static func requestHead(method: String, target: String, headers: [String: String]) -> [String: Any] {
        ["method": method, "target": target, "headers": headers]
    }

    /// The status and the headers out of a reply head, header names
    /// lowercased as they come off a wire.
    static func reply(of head: [String: Any]) throws -> (status: Int, headers: [String: String]) {
        guard let status = head["status"] as? Int, (100...599).contains(status),
              let raw = head["headers"] as? [String: Any]
        else { throw MaerSyncFailure.unreadable }
        var headers: [String: String] = [:]
        for (name, value) in raw {
            guard let value = value as? String else { throw MaerSyncFailure.unreadable }
            headers[name.lowercased()] = value
        }
        return (status, headers)
    }

    /// The target of an address: the path and, when there is one, the
    /// query, which is what a request line carries and what the service
    /// splits again.
    static func target(of url: URL) -> String {
        let path = url.path.isEmpty ? "/" : url.path
        guard let query = url.query, !query.isEmpty else { return path }
        return path + "?" + query
    }
}
