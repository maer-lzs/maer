// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import AVFoundation
import Network
import os
@testable import Maer

/// Measures whether a header the app sets on a request reaches the target of
/// a redirect, for each of the four ways a request leaves the app: the HTTP
/// door, the retrying fetch, the background download session and the
/// stream asset. Three targets per way: the same host and port (the
/// control, so the instrument is shown to see the header), another port on
/// the same host, and another host name. Two kinds of header: one of its
/// own name, and `Authorization` as a source's sign-in carries it. Each line
/// `H0MESS` names the way, the header, the target and whether the header
/// arrived; the cases only require that every target was asked, that the
/// first request carries the header, and that the control carries the
/// header of its own name.
@Suite(.serialized)
@MainActor
struct HeaderRedirectMeasureTests {
    enum Header: String, CaseIterable, Sendable {
        case own, authorization

        var name: String { self == .own ? "X-Maer-Probe" : "Authorization" }
        var value: String { self == .own ? "h0-\(HeaderRedirectMeasureTests.token)" : "Basic aDA6\(HeaderRedirectMeasureTests.token)" }
    }

    nonisolated static let token = String(UUID().uuidString.prefix(8))

    /// A host that records the head of every request and answers by path:
    /// `/start` redirects to `location`, anything else gets a short body.
    /// Unchecked because the listener and its connections are only touched
    /// on the listener's own queue after start; the heads sit behind a lock.
    nonisolated final class RecordingHost: @unchecked Sendable {
        private let listener: NWListener
        private let heads = OSAllocatedUnfairLock(initialState: [String]())
        private let location = OSAllocatedUnfairLock(initialState: "")
        private let status = OSAllocatedUnfairLock(initialState: "302 Found")
        /// The paths that redirect; every other path gets the body.
        let redirecting = OSAllocatedUnfairLock(initialState: "/start")
        private let body: Data
        private let contentType: String
        private(set) var port: UInt16 = 0

        /// Seconds every answer waits before it is sent.
        private let delay: Double

        init(body: Data, contentType: String, delay: Double = 0) throws {
            self.body = body
            self.contentType = contentType
            self.delay = delay
            listener = try NWListener(using: .tcp, on: .any)
        }

        func redirect(to url: URL, status code: Int = 302) {
            location.withLock { $0 = url.absoluteString }
            let reason = [301: "Moved Permanently", 302: "Found", 307: "Temporary Redirect", 308: "Permanent Redirect"][code] ?? "Found"
            status.withLock { $0 = "\(code) \(reason)" }
        }

        /// Every recorded head, lowercased.
        var recorded: [String] { heads.withLock { $0 } }

        func start() async throws {
            listener.newConnectionHandler = { [self] connection in serve(connection) }
            port = try await withCheckedThrowingContinuation { continuation in
                let once = OSAllocatedUnfairLock(initialState: false)
                listener.stateUpdateHandler = { [listener] state in
                    let first = once.withLock { done in
                        let was = done
                        if case .ready = state { done = true } else if case .failed = state { done = true }
                        return !was && done
                    }
                    if first, case .ready = state { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                    if first, case .failed(let error) = state { continuation.resume(throwing: error) }
                }
                listener.start(queue: .global())
            }
        }

        func stop() { listener.cancel() }

        /// The byte range a head asks for (`Range: bytes=a-b` or `bytes=a-`),
        /// clamped to the body; nil without one.
        nonisolated static func range(in head: String, count: Int) -> ClosedRange<Int>? {
            guard count > 0,
                  let line = head.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("range: bytes=") }) else { return nil }
            let bounds = line.dropFirst("range: bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            guard let start = bounds.first.flatMap({ Int($0) }), start < count else { return nil }
            let end = bounds.count > 1 ? Int(bounds[1]) ?? (count - 1) : count - 1
            return start...min(end, count - 1)
        }

        private func serve(_ connection: NWConnection) {
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] data, _, _, _ in
                let head = String(decoding: data ?? Data(), as: UTF8.self)
                heads.withLock { $0.append(head.lowercased()) }
                let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let answer: Data
                if path.hasPrefix(redirecting.withLock { $0 }) {
                    let target = location.withLock { $0 }
                    let line = status.withLock { $0 }
                    answer = Data("HTTP/1.1 \(line)\r\nLocation: \(target)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                } else if let range = Self.range(in: head, count: body.count) {
                    // A stream asset asks in ranges and fails an answer without them.
                    let part = body.subdata(in: range.lowerBound..<(range.upperBound + 1))
                    answer = Data("HTTP/1.1 206 Partial Content\r\nContent-Type: \(contentType)\r\nContent-Range: bytes \(range.lowerBound)-\(range.upperBound)/\(body.count)\r\nContent-Length: \(part.count)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n".utf8) + part
                } else {
                    answer = Data("HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n".utf8) + body
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    connection.send(content: answer, completion: .contentProcessed { _ in
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { connection.cancel() }
                    })
                }
            }
        }
    }

    enum Way: String, CaseIterable, Sendable {
        case door, retryingFetch, backgroundDownload, streamAsset
    }

    enum Target: String, CaseIterable, Sendable {
        case sameOrigin, otherPort, otherHostName
    }

    /// A short CAF tone, so the stream asset has something it can read.
    static func tone() throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("h0-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        try file.write(from: buffer)
        return try Data(contentsOf: url)
    }

    /// Sends one request with the header to `start` on `way`; what the way
    /// answers is not the question, so its error is dropped.
    func ask(_ way: Way, _ header: Header, _ start: URL) async {
        var request = URLRequest(url: start)
        request.setValue(header.value, forHTTPHeaderField: header.name)
        switch way {
        case .door:
            // bearable, because the measured fact is the head the host recorded, not the answer
            _ = try? await HTTP.data(for: request, lane: .api, retry: false)
        case .retryingFetch:
            // bearable, because the measured fact is the head the host recorded, not the answer
            _ = try? await RequestRetryPolicy.fetch(request, once: true)
        case .backgroundDownload:
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("h0-\(UUID().uuidString).caf")
            defer { try? FileManager.default.removeItem(at: destination) }
            // bearable, because the measured fact is the head the host recorded, not the download
            try? await FileDownloader.shared.download(request: request, to: destination, onProgress: { _ in })
        case .streamAsset:
            let asset = AVURLAsset(url: start, options: ["AVURLAssetHTTPHeaderFieldsKey": [header.name: header.value]])
            // bearable, because the measured fact is the head the host recorded, not the asset
            _ = try? await asset.load(.duration)
        }
    }

    @Test("Messung: kommt ein Header nach einer Umleitung beim Ziel an, je Ausgang, Art und Ziel",
          arguments: Way.allCases, Header.allCases)
    func aHeaderAfterARedirect(way: Way, header: Header) async throws {
        let body = try Self.tone()
        let origin = try RecordingHost(body: body, contentType: "audio/x-caf")
        let other = try RecordingHost(body: body, contentType: "audio/x-caf")
        try await origin.start()
        try await other.start()
        defer { origin.stop(); other.stop() }
        let needle = "\(header.name.lowercased()): \(header.value.lowercased())"
        for target in Target.allCases {
            let host: RecordingHost
            let finalURL: URL
            switch target {
            case .sameOrigin:
                host = origin
                finalURL = try #require(URL(string: "http://127.0.0.1:\(origin.port)/final-\(target.rawValue).caf"))
            case .otherPort:
                host = other
                finalURL = try #require(URL(string: "http://127.0.0.1:\(other.port)/final-\(target.rawValue).caf"))
            case .otherHostName:
                host = other
                finalURL = try #require(URL(string: "http://localhost:\(other.port)/final-\(target.rawValue).caf"))
            }
            origin.redirect(to: finalURL)
            let start = try #require(URL(string: "http://127.0.0.1:\(origin.port)/start-\(way.rawValue)-\(target.rawValue)"))
            await ask(way, header, start)
            let atFinal = host.recorded.filter { $0.contains("/final-\(target.rawValue).caf".lowercased()) }
            let carried = atFinal.filter { $0.contains(needle) }.count
            print("H0MESS way=\(way.rawValue) header=\(header.rawValue) target=\(target.rawValue) asked=\(atFinal.count) carried=\(carried)")
            #expect(!atFinal.isEmpty, "the redirect target was asked: \(way.rawValue) \(target.rawValue)")
            // The request that follows a redirect drops `Authorization`, the
            // same origin included, and a stream asset's later requests
            // carry it again, so only a header of its own name shows the
            // instrument.
            if target == .sameOrigin, header == .own {
                #expect(carried == atFinal.count, "the control carries the header on every request: \(carried) of \(atFinal.count)")
            }
        }
        let started = origin.recorded.filter { $0.contains("/start-\(way.rawValue)".lowercased()) }
        let bare = started.filter { !$0.contains(needle) }.count
        #expect(!started.isEmpty && bare == 0, "the first request carries the header: \(bare) of \(started.count) without")
    }
}
#endif
