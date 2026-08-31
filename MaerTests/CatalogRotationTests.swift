// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The row shows today's pick from the good part of the stock. The stock
/// sizes below are the ones MEASURED at archive.org.
struct CatalogRotationTests {
    private func day(_ iso: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: iso)!
    }

    @Test("the page is stable within a day and moves with the date")
    func stableWithinTheDayMovingAcrossDays() {
        let total = 61_112   // netlabels, licensed
        let a = CatalogRotation.page(total: total, rowSize: 12, on: day("2026-08-09"))
        let sameDayLater = CatalogRotation.page(total: total, rowSize: 12,
                                                on: day("2026-08-09").addingTimeInterval(3600 * 13))
        let next = CatalogRotation.page(total: total, rowSize: 12, on: day("2026-08-10"))
        #expect(a == sameDayLater, "a row must not jump between two looks on the same day")
        #expect(a != next, "and it must be a different page tomorrow")
    }

    @Test("the window stays inside the top tenth of the stock")
    func windowIsTheTopTenth() {
        // 6.794 jazz titles, 12 per row ⇒ 56 pages ⇒ deepest item is #672,
        // i.e. still inside the top 10 %.
        var deepest = 0
        for offset in 0..<400 {
            let date = day("2026-08-09").addingTimeInterval(Double(offset) * 86_400)
            let page = CatalogRotation.page(total: 6_794, rowSize: 12, on: date)
            deepest = max(deepest, page * 12)
        }
        #expect(deepest <= 6_794 / 10 + 12)
        #expect(deepest > 12, "over a year it must have moved at all")
    }

    @Test("small surfaces do not rotate")
    func tinySurfacesStayOnPageOne() {
        // A curated surface with fewer than rowSize*10 items has no second
        // page worth showing. Rotating it would only shuffle the same items.
        #expect(CatalogRotation.page(total: 100, rowSize: 12, on: day("2026-08-09")) == 1)
        #expect(CatalogRotation.page(total: 0, rowSize: 12, on: day("2026-08-09")) == 1)
        // Gospel (600 titles) is exactly such a case: 600/10/12 = 5 pages.
        let gospel = CatalogRotation.page(total: 600, rowSize: 12, on: day("2026-08-09"))
        #expect((1...5).contains(gospel))
    }

    @Test("every day of a year yields a valid page")
    func neverOutOfRange() {
        for offset in 0..<365 {
            let date = day("2026-01-01").addingTimeInterval(Double(offset) * 86_400)
            let page = CatalogRotation.page(total: 4_271, rowSize: 12, on: date)
            #expect(page >= 1)
            #expect(page <= 4_271 / 10 / 12 + 1)
        }
    }

    private func items(_ ids: [String]) -> [LibraryItem] {
        ids.map { LibraryItem(id: $0, media: nil, addedAt: nil) }
    }

    @Test("a twin sorts to the back of the later shelf, and no shelf empties")
    func twinsMoveBackWithoutDiscard() {
        // The case as reported: one album standing on top of two genre
        // shelves at once. It belongs in both; only the same excerpt on
        // top twice is wrong.
        let stock = ["rock": items(["twin", "r1", "r2"]),
                     "indie": items(["twin", "i1", "i2"])]
        let out = CatalogRotation.twinFree(stock, order: ["rock", "indie"],
                                           previewLimit: 12)
        #expect(out["rock"]?.map(\.id) == ["twin", "r1", "r2"],
                "the first shelf in browse order keeps its excerpt")
        #expect(out["indie"]?.map(\.id) == ["i1", "i2", "twin"],
                "the later shelf moves the twin back and loses nothing")
    }

    @Test("the rule follows browse order, not arrival order")
    func browseOrderDecides() {
        let stock = ["a": items(["x"]), "b": items(["x", "y"])]
        // The same stock through two different browse orders proves the
        // dictionary (arrival) plays no part in the outcome.
        let ab = CatalogRotation.twinFree(stock, order: ["a", "b"], previewLimit: 12)
        let ba = CatalogRotation.twinFree(stock, order: ["b", "a"], previewLimit: 12)
        #expect(ab["b"]?.map(\.id) == ["y", "x"])
        #expect(ba["b"]?.map(\.id) == ["x", "y"])
    }

    @Test("only the visible preview counts as standing on top")
    func onlyThePreviewCounts() {
        // An item beyond the preview limit of the earlier shelf was never
        // on screen there, so the later shelf may show it in front.
        let stock = ["a": items(["1", "2", "3"]), "b": items(["3", "z"])]
        let out = CatalogRotation.twinFree(stock, order: ["a", "b"], previewLimit: 2)
        #expect(out["b"]?.map(\.id) == ["3", "z"])
    }

    @Test("the total survives the reorder on the counted surfaces")
    func totalsStay() {
        let stock: [String: (items: [LibraryItem], total: Int?)] =
            ["a": (items(["x"]), 400), "b": (items(["x", "y"]), nil)]
        let out = CatalogRotation.twinFree(stock, order: ["a", "b"], previewLimit: 12)
        #expect(out["a"]?.total == 400)
        #expect(out["b"]?.items.map(\.id) == ["y", "x"])
        #expect(out["b"]?.total == nil)
    }
}
#endif
