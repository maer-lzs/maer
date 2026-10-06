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
            for line in code.split(separator: "\n") where line.contains("HTTP.upload(") {
                callers.append(url.lastPathComponent)
                if line.contains("lane:") && !line.contains("lane: .upload") { wrong.append(String(line)) }
            }
        }
        #expect(callers == ["APIClient.swift"], "uploads found in \(callers)")
        #expect(wrong.isEmpty, "an upload on another lane: \(wrong)")
    }
}
#endif
