// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Network
import os
@testable import Maer

/// The behaviour the plist fence is for, measured on the wire: the app's
/// own door reaches a plain http address OUTSIDE the private ranges. This
/// runs inside the Maer host, so it sees the app's own transport security.
///
/// The precondition is asked below transport security: a hand-written
/// HTTP/1.1 exchange over Network.framework, which the platform's rule
/// does not cover. If no target answers there, there is no network and the
/// case is SKIPPED, never passed. If one answers there and the app's door
/// gets URLError -1022 back, the declaration is void, which is exactly the
/// finding this exists for.
struct TransportSecurityWitnessTests {
    /// Public first, the mesh test bench second; whichever answers below
    /// the rule is measured through the door.
    static let targets = [
        URL(string: "http://example.com/")!,
        URL(string: "http://100.64.0.2:8811/v1/health")!,
    ]

    static func answering() async -> [URL] {
        var found: [URL] = []
        for target in targets {
            if let status = try? await PlainHTTP.status(of: target), status == 200 { found.append(target) }
        }
        return found
    }

    @Test("die Tuer der App erreicht eine plain-http-Adresse ausserhalb privater Bereiche",
          .enabled("no plain http host answers below the platform's rule, so there is nothing to measure") {
              let found = await TransportSecurityWitnessTests.answering()
              return !found.isEmpty
          })
    func theDoorReachesAPlainAddressOutsidePrivateRanges() async throws {
        let reachable = await Self.answering()
        // The precondition can turn between the trait and here (measured in
        // a gate: true in `.enabled`, false six seconds later). That is a
        // network that went away, not a finding: the case is cancelled, which
        // the report shows as skipped, never as passed and never as red.
        guard !reachable.isEmpty else {
            try Test.cancel("the plain http host stopped answering between the check and the measurement")
        }
        for target in reachable {
            do {
                let (_, response) = try await HTTP.data(for: URLRequest(url: target), retry: false)
                #expect(response?.statusCode == 200, "the door did not get the 200 the wire gives for \(target.host ?? "-")")
            } catch {
                let code = (error as? URLError)?.code.rawValue ?? 0
                Issue.record("the door failed for \(target.host ?? "-") with URLError \(code); -1022 means the declaration is void")
            }
        }
    }
}

/// The smallest HTTP/1.1 exchange over Network.framework: one GET, the
/// status line back. Below App Transport Security by construction, which
/// is the whole reason it exists here.
nonisolated enum PlainHTTP {
    enum Failure: Error { case noStatusLine, connectionFailed(String), timeout }

    static func status(of url: URL, timeout: Double = 6) async throws -> Int {
        let host = url.host ?? ""
        let port = UInt16(url.port ?? 80)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        try await ready(connection, timeout: timeout)
        let target = url.path.isEmpty ? "/" : url.path
        let head = "GET \(target) HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\n\r\n"
        try await send(connection, Data(head.utf8))
        var received = Data()
        while received.range(of: Data("\r\n".utf8)) == nil {
            let (chunk, complete) = try await receive(connection, timeout: timeout)
            if let chunk { received.append(chunk) }
            if complete { break }
        }
        connection.cancel()
        let statusLine = String(decoding: received.prefix(while: { $0 != 13 }), as: UTF8.self)
        let parts = statusLine.split(separator: " ")
        guard statusLine.hasPrefix("HTTP/1."), parts.count > 1, let status = Int(parts[1]) else { throw Failure.noStatusLine }
        return status
    }

    /// Resolves once, on ready, failure, cancellation or the deadline,
    /// whichever comes first; a state handler fires more than once.
    static func ready(_ connection: NWConnection, timeout: Double) async throws {
        let once = OSAllocatedUnfairLock(initialState: false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                let first = once.withLock { done -> Bool in
                    if done { return false }
                    switch state {
                    case .ready, .failed, .cancelled: done = true; return true
                    default: return false
                    }
                }
                if first {
                    switch state {
                    case .ready: continuation.resume()
                    case .failed(let error): continuation.resume(throwing: Failure.connectionFailed("\(error)"))
                    default: continuation.resume(throwing: Failure.connectionFailed("cancelled"))
                    }
                }
            }
            connection.start(queue: DispatchQueue(label: "transport-security-witness"))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                let first = once.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first {
                    connection.cancel()
                    continuation.resume(throwing: Failure.timeout)
                }
            }
        }
    }

    static func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// One receive with a deadline: a host that keeps the connection alive
    /// never signals an end, so the deadline is the only way out.
    static func receive(_ connection: NWConnection, timeout: Double) async throws -> (Data?, Bool) {
        let once = OSAllocatedUnfairLock(initialState: false)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data?, Bool), Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                let first = once.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first {
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (data, complete)) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                let first = once.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first {
                    connection.cancel()
                    continuation.resume(throwing: Failure.timeout)
                }
            }
        }
    }
}
#endif
