#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// S-Pass regression: the model types must stay decodable OFF the main actor
/// (nonisolated conformances) — a re-isolated model would silently move the
/// big decodes back onto the UI thread (compile error in Swift 6, runtime
/// assertion here in mode 5).
struct OffMainDecodeTests {

    private let libraryPageJSON = Data("""
    {"results":[{"id":"b1","addedAt":123,"media":{"metadata":{"title":"T","authorName":"A"},"duration":10}}],"total":1}
    """.utf8)

    @Test("Library page decodes identically on a detached task")
    func decodeOffMainEqualsOnMain() async throws {
        let onMain = try JSONDecoder().decode(LibraryItemsResponse.self, from: libraryPageJSON)
        let offMain = try await Task.detached(priority: .userInitiated) { [libraryPageJSON] in
            try JSONDecoder().decode(LibraryItemsResponse.self, from: libraryPageJSON)
        }.value
        #expect(onMain.results.map(\.id) == offMain.results.map(\.id))
        #expect(onMain.total == offMain.total)
        #expect(offMain.results.first?.title == "T")
    }

    @Test func subsonicEnvelopeDecodesOffMain() async throws {
        let json = Data("""
        {"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{"album":[{"id":"al1","name":"N","artist":"Ar","created":"2026-01-01T00:00:00.000Z"}]}}}
        """.utf8)
        let env = try await Task.detached {
            try JSONDecoder().decode(SubsonicEnvelope.self, from: json)
        }.value
        #expect(env.subsonicResponse.status == "ok")
        #expect(env.subsonicResponse.albumList2?.album?.first?.id == "al1")
    }
}
#endif
