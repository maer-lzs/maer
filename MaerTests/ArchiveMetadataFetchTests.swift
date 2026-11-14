// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The archive.org metadata fetch names every exit. A status other than
/// 2xx is refused BEFORE the decoder sees the body, and the reason of a
/// failure is one word: cancelled, the URLError code, the status, decode.
/// A row of fetches that died in a recompute reads as `cancelled`, never
/// as a broken source.
struct ArchiveMetadataFetchTests {
    @Test("A status outside 2xx is rejected as a status, before the decoder")
    func statusIsRefusedBeforeDecoding() throws {
        #expect(throws: Never.self) { try ArchiveOrgClient.checkStatus(200) }
        #expect(throws: Never.self) { try ArchiveOrgClient.checkStatus(nil) }
        do {
            try ArchiveOrgClient.checkStatus(503)
            Issue.record("a 503 passed to the decoder")
        } catch let error as APIError {
            guard case .http(let code, _) = error else { Issue.record("wrong error \(error)"); return }
            #expect(code == 503)
        }
    }

    @Test("The reason is one word per outcome: cancelled, urlError, status, decode")
    func reasonNamesTheExit() {
        #expect(ArchiveOrgClient.fetchReason(CancellationError()) == "cancelled")
        #expect(ArchiveOrgClient.fetchReason(URLError(.cancelled)) == "cancelled")
        #expect(ArchiveOrgClient.fetchReason(URLError(.timedOut)) == "urlError=-1001")
        #expect(ArchiveOrgClient.fetchReason(APIError.http(429, "")) == "status=429")
        #expect(ArchiveOrgClient.fetchReason(FreeCatalog.CatalogDecodeError(status: 200, answerPrefix: "<html")) == "decode")
    }

    @Test("The measurement line carries id, path, status, bytes, files, ms and the reason")
    func lineCarriesTheMeasurement() {
        let line = ArchiveOrgClient.metadataLine(identifier: "otr_x", path: "metadata", status: 200, bytes: 8300, files: 12, ms: 412, reason: "ok")
        #expect(line == "FREECAT metadata id=otr_x path=metadata status=200 bytes=8300 files=12 ms=412 reason=ok")
        let failed = ArchiveOrgClient.metadataLine(identifier: "otr_x", path: "metadataOnly", status: nil, bytes: 0, files: 0, ms: 3, reason: "cancelled")
        #expect(failed.hasSuffix("path=metadataOnly status=- bytes=0 files=0 ms=3 reason=cancelled"))
    }
}
#endif
