// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Every tile of a mixed row says its kind, from the one glyph table;
/// the storage lines carry the same glyphs.
struct MixedRowGlyphTests {
    @Test("Art und Platzhalter fragen dieselbe Zuordnung")
    func kindAndPlaceholderAgree() {
        let ids = ["rss:feed#e1", "abspod:p1:e1", "sub:album:a1", "jf:album:a1", "jf:book:b1",
                   "radio:s1", "lv:123", "gut:9", "lva:work", "lva:work#2", "jam:7", "li-1", "zzz:x"]
        for id in ids {
            for form: ProgressMark.StartedForm? in [nil, .album] {
                #expect((MediaFamily.kind(for: id, markedForm: form)?.systemImage ?? "waveform")
                        == MediaFamily.placeholderSymbol(for: id, markedForm: form), "\(id) \(String(describing: form))")
            }
        }
        #expect(MediaFamily.kind(for: "zzz:x") == nil, "an id no family knows is marked with nothing")
        #expect(MediaFamily.kind(for: "lva:work", markedForm: .album) == .music)
    }

    /// The mixed rows, counted at the code on 05.10.: where their tiles
    /// are built, how many tile branches each file marks, and the mixers
    /// whose callers ARE the mixed rows. A new caller of a mixer is a new
    /// mixed row and stands here with its marks.
    static let marks: [String: (count: Int, reason: String)] = [
        "Sources/Views/MixedMediaPage.swift": (9, "Continue card 2, Recently Added tile 2, Listen Again page 3, the continue page's tile 2"),
        "Sources/Views/HomeView.swift": (6, "Listen Again row 3, Rediscover tile 3"),
        "Sources/Views/CatalogMixRow.swift": (2, "feed and catalog tile, marked in the Browse row only"),
        "Sources/Views/BrowseRow.swift": (2, "recommended show and free-music title; the catalog share marks through its tile"),
    ]

    static let mixers: [String: (callers: [String: Int], reason: String)] = [
        "HomeSections.byRecency(": (["Sources/Views/HomeView.swift": 2], "Keep Listening, row and page ids"),
        "RecentlyPlayedRow.merged(": (["Sources/Views/HomeView.swift": 1, "Sources/Views/MixedMediaPage.swift": 1,
                                       "Sources/Views/Music/MusicView.swift": 1],
                                      "Listen Again, row and page; the music tab's Recently Played holds music only and carries no marks"),
        "BrowseMix.interleave(": (["Sources/Views/HomeView.swift": 1], "the Browse row's three shares"),
        "computeRediscover(": (["Sources/Views/HomeView.swift": 1], "Rediscover, row and pool"),
        "CatalogMix.tiles(for: .home": (["Sources/Views/HomeView.swift": 1], "feeds and catalogs on Start"),
        "marksKind: true": (["Sources/Views/BrowseRow.swift": 1], "the catalog tile marks its kind in the Browse row only"),
    ]

    static func code(_ path: String) throws -> String {
        SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
    }

    /// Every Swift file under Sources, comment lines stripped.
    static func sources() throws -> [String: String] {
        let root = SourceTree.root.appendingPathComponent("Sources")
        var files: [String: String] = [:]
        for url in SourceTree.files(under: root) {
            guard url.pathExtension == "swift" else { continue }
            // The one way to name a walked file (`SourceTree.relativePath`):
            // the walker hands out /private/tmp where the root says /tmp.
            let path = SourceTree.relativePath(of: url)
            files[path] = SyncContractFenceTests.stripped(try String(contentsOf: url, encoding: .utf8))
        }
        return files
    }

    static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test("jede gemischte Reihe traegt die Glyphe je Kachel, und jeder Mischer steht im Bestand", .needsTheSources)
    func everyMixedRowMarksItsTiles() throws {
        let files = try Self.sources()
        #expect(files.count > 100, "the walk found only \(files.count) files")
        // A tile marks its kind first in its stack of marks.
        let marked = files.compactMapValues { text -> Int? in
            let n = Self.count(".stackedKind(", in: text)
            return n > 0 ? n : nil
        }
        #expect(marked == Self.marks.mapValues(\.count), "kind marks per file: \(marked)")
        for (mixer, entry) in Self.mixers {
            let stock = entry.callers
            let callers = files.compactMapValues { text -> Int? in
                let n = text.split(separator: "\n").filter {
                    $0.contains(mixer) && !$0.contains("func ")
                }.count
                return n > 0 ? n : nil
            }
            #expect(callers == stock, "\(mixer) is called at \(callers): a new mixed row stands in this stock with its marks")
        }
    }

    @Test("die Speicher-Zeilen tragen die Glyphe ihrer Art, Klassik heisst Musik", .needsTheSources)
    func theStorageLinesAndTheClassicalPlaceholder() throws {
        let settings = try Self.code("Sources/Views/SettingsView.swift")
        #expect(settings.contains("Label(kind.label, systemImage: kind.glyphKind.systemImage)"),
                "the storage lines lost their glyphs")
        #expect(!settings.contains("Text(kind.label).padding(.leading, 28)"))
        // The free music stands in the Browse row now.
        let rows = try Self.code("Sources/Views/BrowseRow.swift")
        #expect(rows.contains("markedForm: ListeningStore.startedForm(item.id) ?? .album"),
                "a classical work not started yet shows a book")
    }
}
#endif
