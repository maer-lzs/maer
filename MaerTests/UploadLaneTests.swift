// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// An upload is bounded only by the wait without movement, never by a
/// total: the API lane's 60 s cap ended a book's upload mid-stream.
struct UploadLaneTests {
    @Test("ein Hochladen kennt keine Gesamtgrenze der API-Spur")
    func anUploadHasNoTotalCapOfTheAPILane() throws {
        let upload = HTTP.session(.upload)
        #expect(upload !== HTTP.session(.api), "the upload rides the API lane's session again")
        #expect(upload.configuration.timeoutIntervalForResource >= 86_400,
                "a total cap of \(upload.configuration.timeoutIntervalForResource) s ends a long upload")
        #expect(HTTP.session(.api).configuration.timeoutIntervalForResource <= 60,
                "the precondition: the API lane keeps its short total")
    }

    /// Every `HTTP.upload(` call of a text, up to its closing bracket, so a
    /// call written over several lines is read whole.
    nonisolated static func uploadCalls(in code: String) -> [String] {
        var calls: [String] = []
        var search = code.startIndex
        while let start = code.range(of: "HTTP.upload(", range: search..<code.endIndex) {
            var depth = 1
            var index = start.upperBound
            while index < code.endIndex, depth > 0 {
                if code[index] == "(" { depth += 1 } else if code[index] == ")" { depth -= 1 }
                index = code.index(after: index)
            }
            calls.append(String(code[start.lowerBound..<index]))
            search = index
        }
        return calls
    }

    @Test("jedes Hochladen nimmt die Spur fuer Uploads", .needsTheSources)
    func everyUploadTakesTheUploadLane() throws {
        let door = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/HTTP.swift"), encoding: .utf8))
        #expect(door.contains("fromFile file: URL, lane: Lane = .upload)"), "the upload door defaults to another lane")
        var callers: [String] = []
        var wrong: [String] = []
        let root = SourceTree.root.appendingPathComponent("Sources")
        let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: url, encoding: .utf8))
            for call in Self.uploadCalls(in: code) {
                callers.append(url.lastPathComponent)
                if call.contains("lane:") && !call.contains("lane: .upload") { wrong.append(call) }
            }
        }
        #expect(callers == ["APIClient.swift"], "uploads found in \(callers)")
        #expect(wrong.isEmpty, "an upload on another lane: \(wrong)")
        // Calibration: a call over three lines is read whole.
        let wrapped = Self.uploadCalls(in: "try await HTTP.upload(for: request,\n    fromFile: body,\n    lane: .api)\nlet x = 1")
        #expect(wrapped.count == 1 && wrapped[0].contains("lane: .api"), "\(wrapped)")
    }
}
#endif
