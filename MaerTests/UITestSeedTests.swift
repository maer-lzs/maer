// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The DEBUG-only UI-test seed must do NOTHING unless the process was launched
/// with `-uitest`. So a normal launch (and the whole test process) is
/// unaffected. In Release the type does not exist at all (#if DEBUG).
@MainActor
struct UITestSeedTests {
    @Test("without -uitest the seed is inactive and applyIfRequested is a no-op")
    func inactiveWithoutArgument() {
        // The unit-test process is not launched with -uitest.
        #expect(UITestSeed.isActive == false)
        let loggedInBefore = AppSession.shared.authViewModel.isLoggedIn
        UITestSeed.applyIfRequested()
        #expect(AppSession.shared.authViewModel.isLoggedIn == loggedInBefore)
    }

    /// Milliseconds since 1970 for the year 2000: no seeded progress lies
    /// before it, so a value given in seconds shows at once.
    nonisolated static let year2000Ms: Double = 946_684_800_000

    @Test("a seeded moment is in milliseconds like the server's")
    func seededMomentsAreMilliseconds() {
        let now = Date().timeIntervalSince1970 * 1000
        let monthAgo = UITestSeed.msAgo(35 * 24 * 3600)
        #expect(monthAgo > Self.year2000Ms)
        #expect(abs((now - monthAgo) - 35 * 24 * 3600 * 1000) < 60_000)
    }

    @Test("no seeded progress lies before 2000", .needsTheSources)
    func noSeededProgressBefore2000() throws {
        let seed = try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/UITestSeed.swift"), encoding: .utf8)
        let arguments = seed.components(separatedBy: "lastUpdate: ").dropFirst()
            .map { String($0.prefix(while: { $0 != ")" && $0 != "," })) }
        #expect(!arguments.isEmpty)
        for argument in arguments {
            if argument.hasPrefix("msAgo(") { continue }
            // The detail a seeded book answers with copies the moment of its
            // own seeded progress, which this loop checks where it is set.
            if argument == "progress.lastUpdate" { continue }
            let literal = Double(argument.replacingOccurrences(of: "_", with: ""))
            #expect((literal ?? 0) >= Self.year2000Ms, "a seeded lastUpdate is not milliseconds: \(argument)")
        }
    }

    /// A server sends a progress with its time; a seeded one without it
    /// starts the player at 0 while Continue shows the fraction.
    @Test("jeder geseedete Stand traegt seine Zeit wie ein Server", .needsTheSources)
    func everySeededProgressCarriesItsTime() throws {
        let seed = try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/UITestSeed.swift"), encoding: .utf8)
        // Each call ends with `))` (its own and the entry's); a single `)`
        // closes `msAgo(…)` inside it.
        let calls = seed.components(separatedBy: "BookProgress(").dropFirst()
            .map { $0.components(separatedBy: "))").first ?? "" }
        #expect(calls.count == 4, "the fence read the seeded progresses: \(calls.count)")
        for call in calls {
            #expect(call.contains("currentTime:"), "a seeded progress without its time: \(call)")
        }
        // Every seeded book has a track as long as itself, so a position lands.
        #expect(seed.contains("contentUrl: seedBookAudioURL"))
        // The detail the player starts from carries the same progress.
        #expect(seed.contains("userMediaProgress: entry.progress.map { progress in"))
        #expect(!seed.contains("userMediaProgress: nil)) }"), "the seeded detail knows no position again")
    }

    @Test("without -uitest-store every fixture keeps the seed's own name")
    func storeNamesStayOffWithoutTheirArgument() {
        #expect(UITestSeed.seedsStorePictures == false)
        let book = UITestSeed.shown("Seed Book One", by: "Ada Author")
        #expect(book.title == "Seed Book One" && book.by == "Ada Author")
        #expect(UITestSeed.shown("Seed Radio One") == "Seed Radio One")
        #expect(UITestSeed.seedRadioStations.allSatisfy { $0.faviconURL == nil })
    }

    /// The fence of the store pictures: every name the seed's source hands
    /// to a fixture, the filler rows expanded over their ranges, comes out
    /// of the store table without a placeholder. A byline counts as covered
    /// when its line names a work, which brings its own author.
    @Test("under -uitest-store no fixture name shows a placeholder", .needsTheSources)
    func storeNamesCoverEveryFixture() throws {
        let full = try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/UITestSeed.swift"), encoding: .utf8)
        let tables = try #require(full.range(of: "extension UITestSeed {"))
        let source = String(full[..<tables.lowerBound])
        let works = UITestSeed.StoreNames.works, names = UITestSeed.StoreNames.names
        let markers = ["Seed", "seeded", "Filler", "Now Playing", "Author", "Host", "Catalog", "Orchestra",
                       "Reader", "Sprout", "Bloom", "Petal", "Backing Band", "Teil ", "Chapter "]
        func strings(_ pattern: String, in line: String) -> [String] {
            let regex = try! NSRegularExpression(pattern: pattern)
            return regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap {
                Range($0.range(at: 1), in: line).map { String(line[$0]) }
            }
        }
        func ranges(_ pattern: String, in text: Substring) -> [ClosedRange<Int>] {
            strings(pattern, in: String(text)).compactMap {
                let ends = $0.components(separatedBy: "...").compactMap(Int.init)
                return ends.count == 2 ? ends[0]...ends[1] : nil
            }
        }
        // A line with `\($0)` takes the nearest range above it or on it,
        // a line with `\(n)` the first range below it.
        var lines: [String] = []
        var offset = source.startIndex
        for line in source.components(separatedBy: "\n") {
            defer { offset = source.index(offset, offsetBy: line.count + 1, limitedBy: source.endIndex) ?? source.endIndex }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            if line.contains("\\($0)") {
                let range = try #require(ranges(#"\((\d+\.\.\.\d+)\)\.map \{"#,
                                                in: source[..<source.index(offset, offsetBy: line.count)]).last)
                lines += range.map { line.replacingOccurrences(of: "\\($0)", with: "\($0)") }
            } else if line.contains("\\(n)") {
                let range = try #require(ranges(#"\((\d+\.\.\.\d+)\)\.map\("#, in: source[offset...]).first)
                lines += range.map { line.replacingOccurrences(of: "\\(n)", with: "\($0)") }
            } else {
                lines.append(line)
            }
        }
        var checked = 0
        for line in lines {
            let titles = strings(#"\b(?:title|name|series|description): (?:shown\()?"([^"]+)""#, in: line)
                + strings(#"shown\("([^"]+)""#, in: line)
                + strings(#"chapter\(\d+, \d+, \d+, "([^"]+)"\)"#, in: line)
            let bylines = strings(#"\b(?:author|artist|by): "([^"]+)""#, in: line)
            let lineNamesAWork = titles.contains { works[$0] != nil }
            for title in titles {
                let shown = works[title]?.title ?? names[title] ?? title
                #expect(!markers.contains { shown.contains($0) }, "\(title) shows as \(shown)")
                checked += 1
            }
            for byline in bylines where !lineNamesAWork {
                let shown = names[byline] ?? byline
                #expect(!markers.contains { shown.contains($0) }, "\(byline) shows as \(shown)")
                checked += 1
            }
        }
        // The scan itself: 16 filler books, 20 episodes, 20 albums, 12
        // stations, 4 classics and the named fixtures. A scan that finds
        // nothing proves nothing.
        #expect(checked > 100, "the scan read \(checked) names")
        // The table holds no placeholder of its own.
        for shown in works.values.flatMap({ [$0.title, $0.by] }) + names.values
            + UITestSeed.StoreNames.fullBookChapters {
            #expect(!markers.contains { shown.contains($0) }, "the store table shows \(shown)")
        }
    }

    /// A seed name outside the seed's own file (the radio regions) goes
    /// through the same table, or the store pictures show it raw.
    @Test("a seed name elsewhere in the sources goes through UITestSeed.shown", .needsTheSources)
    func seedNamesElsewhereGoThroughTheTable() throws {
        let sources = SourceTree.root.appendingPathComponent("Sources")
        let files = SourceTree.files(under: sources)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "UITestSeed.swift" }
        let literal = try NSRegularExpression(pattern: #"(UITestSeed\.shown\()?"((?:Seed|Filler) [^"]*)""#)
        var found = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in literal.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let range = try #require(Range(match.range(at: 2), in: text))
                let name = String(text[range])
                found += 1
                #expect(match.range(at: 1).location != NSNotFound,
                        "\(file.lastPathComponent): \"\(name)\" is not read through UITestSeed.shown")
                #expect(UITestSeed.StoreNames.names[name] != nil, "\(name) has no store name")
            }
        }
        #expect(found >= 3, "the scan found \(found) seed names outside the seed")
    }
}
#endif
