// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The library is whole by its distinct ids, never by the number of
/// entries, and a server without a total is paged until a short page.
struct LibraryCompletenessTests {
    @Test("voll ist die Liste mit so vielen verschiedenen Kennungen wie total; ohne total endet sie an einer kurzen Seite")
    func wholeByDistinctIds() {
        typealias Rule = LibraryCompleteness
        #expect(Rule.isWhole(distinctIds: 200, total: 200, endedShort: false))
        #expect(!Rule.isWhole(distinctIds: 199, total: 200, endedShort: true), "a book sent twice made the list whole")
        #expect(Rule.asksMore(distinctIds: 199, total: 200))
        #expect(!Rule.asksMore(distinctIds: 200, total: 200))
        // No total: the first page is not all of it.
        #expect(Rule.asksMore(distinctIds: 50, total: Rule.unknownTotal))
        #expect(!Rule.isWhole(distinctIds: 50, total: Rule.unknownTotal, endedShort: false),
                "the length of the first page counted as the total")
        #expect(Rule.isWhole(distinctIds: 73, total: Rule.unknownTotal, endedShort: true))
    }

    @Test("die Bibliothek fragt die Regel und sagt einen Abbruch beim Nachladen", .needsTheSources)
    func theLibraryAsksTheRule() throws {
        let library = try FetchAnswerTests.squeezedSource("Sources/ViewModels/LibraryViewModel.swift")
        #expect(library.contains("guard LibraryCompleteness.isWhole(distinctIds: distinct, total: total, endedShort: endedShort) else {"))
        #expect(!library.contains("guard accumulated.count >= total else { return nil }"), "the count of entries decides again")
        #expect(library.contains(#"Logger.library.error("LIBRARY page \(page) failed, the list stays partial:"#), "the abort is silent")
        let client = try FetchAnswerTests.squeezedSource("Sources/Networking/APIClient.swift")
        #expect(client.contains("return (response.results, response.total ?? LibraryCompleteness.unknownTotal)"))
    }
}
#endif
