// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import SwiftUI
import Testing
@testable import Maer

/// Every mark on a cover takes one size per class of cover: a tile's
/// marks one side, a row's marks another, from one place
/// (`CoverMarkSize`). The downloaded mark of a tile stood at 30 pt among
/// marks of 22 and covered the title printed on the cover.
@MainActor
struct CoverMarkSizeTests {
    /// The rendered size of a view, in points.
    static func size(_ view: some View, _ type: DynamicTypeSize) -> CGSize {
        let renderer = ImageRenderer(content: view.environment(\.dynamicTypeSize, type))
        renderer.scale = 1
        return renderer.uiImage?.size ?? .zero
    }

    /// Each mark of a tile's stack, alone.
    static let tileMarks: [(String, StandardCoverMarks)] = [
        ("kind", StandardCoverMarks(kind: .podcasts, coverSide: 500)),
        ("lock", StandardCoverMarks(lock: .premium, coverSide: 500)),
        ("refused", StandardCoverMarks(lock: .refused, coverSide: 500)),
        ("downloaded", StandardCoverMarks(availability: .downloaded, coverSide: 500)),
        ("offline", StandardCoverMarks(availability: .offline, coverSide: 500)),
        ("failed", StandardCoverMarks(availability: .failed, coverSide: 500)),
        ("finished", StandardCoverMarks(finished: true, coverSide: 500)),
        ("favourite", StandardCoverMarks(favourite: true, coverSide: 500)),
    ]

    @Test("every mark of a tile has the one side of the rule, at the standard size and at AX3", arguments: [DynamicTypeSize.large, .accessibility3])
    func tileMarksAreOneSize(_ type: DynamicTypeSize) {
        let side = CoverMarkSize.diameter(.tile, type) + 2 * CoverMarkSize.inset(.tile)
        for (name, mark) in Self.tileMarks {
            let measured = Self.size(mark, type)
            #expect(abs(measured.width - side) <= 0.5 && abs(measured.height - side) <= 0.5,
                    "\(name) at \(type): \(measured), the rule says \(side)")
        }
        let count = Self.size(StandardCoverMarks(count: 12, coverSide: 500), type)
        #expect(abs(count.height - side) <= 0.5, "the count at \(type): \(count.height), the rule says \(side)")
    }

    @Test("the rule: a tile's marks stop growing at the first accessibility size, a row's at 24 pt")
    func theCaps() {
        #expect(CoverMarkSize.diameter(.tile, .large) == 22)
        #expect(CoverMarkSize.diameter(.tile, .accessibility3) == CoverMarkSize.diameter(.tile, .accessibility1))
        #expect(CoverMarkSize.diameter(.row, .large) == 18)
        #expect(CoverMarkSize.diameter(.row, .accessibility3) == 24)
        #expect(CoverMarkSize.diameter(.row, .large) < CoverMarkSize.diameter(.tile, .large))
    }

    @Test("the two marks of a row have the one side of the rule, at the standard size and at AX3", arguments: [DynamicTypeSize.large, .accessibility3])
    func rowMarksAreOneSize(_ type: DynamicTypeSize) {
        let side = CoverMarkSize.diameter(.row, type)
        for (name, mark) in [("downloaded", AnyView(DownloadedMark(size: .row))),
                             ("offline", AnyView(OfflineUnavailableBadge(size: .row)))] {
            let measured = Self.size(mark, type)
            #expect(abs(measured.width - side) <= 0.5 && abs(measured.height - side) <= 0.5,
                    "\(name) at \(type): \(measured), the rule says \(side)")
        }
    }

    // MARK: The fence over the inventory

    /// The marks on covers and where each stands.
    static let inventory: [(mark: String, file: String)] = [
        ("struct KindGlyph", "Sources/Views/KindGlyph.swift"),
        ("struct PremiumLockBadge", "Sources/Views/Podcasts/PremiumBadge.swift"),
        ("struct OfflineUnavailableBadge", "Sources/Views/CoverBadge.swift"),
        ("struct DownloadedMark", "Sources/Views/CoverBadge.swift"),
        ("struct StandardCoverMarks", "Sources/Views/CoverGlyphStack.swift"),
    ]

    /// What the fence finds wrong in one mark's declaration: no size from
    /// the rule, or a size of its own (a text style or a point size).
    static func faults(of mark: String, in source: String) -> [String] {
        guard let start = source.range(of: mark) else { return ["\(mark) is not in its file"] }
        let rest = source[start.upperBound...]
        let body = String(rest.range(of: "\nstruct ").map { rest[..<$0.lowerBound] } ?? rest)
        var found: [String] = []
        if !body.contains("CoverMarkSize.") { found.append("\(mark) takes no size from CoverMarkSize") }
        for own in [".font(.caption2)", ".font(.caption)", "@ScaledMetric"] where body.contains(own) {
            found.append("\(mark) has a size of its own: \(own)")
        }
        return found
    }

    @Test("Fence: every mark of the inventory takes its size from the rule and none of its own", .needsTheSources)
    func everyMarkAsksTheRule() throws {
        for entry in Self.inventory {
            let source = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
                .appendingPathComponent(entry.file), encoding: .utf8))
            let found = Self.faults(of: entry.mark, in: source)
            #expect(found.isEmpty, "\(found)")
        }
        let row = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
            .appendingPathComponent("Sources/Views/MediaRowContent.swift"), encoding: .utf8))
        #expect(row.contains("OfflineUnavailableBadge(size: .row)"), "the row draws its own offline mark")
    }

    @Test("Counter probe: the fence tears for a mark with a size of its own and for an entry without its mark")
    func theFenceTears() {
        let own = "struct Probe: View { var body: some View { Image(systemName: \"x\").font(.caption2).frame(width: CoverMarkSize.diameter(.tile, size)) } }"
        #expect(Self.faults(of: "struct Probe", in: own) == ["struct Probe has a size of its own: .font(.caption2)"])
        #expect(Self.faults(of: "struct Gone", in: own) == ["struct Gone is not in its file"])
        let bare = "struct Bare: View { var body: some View { Image(systemName: \"x\") } }"
        #expect(Self.faults(of: "struct Bare", in: bare) == ["struct Bare takes no size from CoverMarkSize"])
    }
}
#endif
