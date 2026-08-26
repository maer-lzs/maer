// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

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
        // page worth showing — rotating it would only shuffle the same items.
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
}
#endif
