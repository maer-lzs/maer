// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A view that shows the download state must either observe the download
/// manager itself or be handed the value. Reading it through `.shared`
/// without observing is only current while some page above happens to
/// observe, and moving that page's observation into a leaf silently makes
/// the read stale.
///
/// **This is the other half of `ObserverPlaceFenceTests`.** That fence counts
/// where an observation sits; this one counts where state is read WITHOUT
/// one. Measured before it was built: the book context menu read the state
/// this way and was only current in the search because the search page
/// observed, until the page stopped observing.
///
/// **What it cannot see:** a read through another object, such as a view
/// model that consults the manager while computing a list. Those are only
/// healed at the source, by a finer publisher.
struct UnobservedReadFenceTests {
    /// Reads per file, measured. The numbers may only fall, a file that
    /// reaches zero leaves the list, and every slice writes back the value.
    ///
    /// Why each one still stands:
    /// - `BookGridComponents.swift`: the downloaded badge of `BookDownloadRow`;
    ///   the library page above it observes until the publisher is finer.
    /// - `PodcastComponents.swift`: three reads in `PodcastEpisodeRow`
    ///   (delete in the swipe menu, offline dimming, downloaded badge) that
    ///   rely on the host; one closure handed to `MediaAvailabilityScope`,
    ///   which observes and evaluates it, so that one is covered at run time
    ///   although the text cannot show it.
    /// - `PodcastHelpers.swift`: the episode context menu, the same class as
    ///   the book menu before it observed.
    static let stock = [
        "BookGridComponents.swift": 1,
        "PodcastComponents.swift": 4,
        "PodcastHelpers.swift": 2,
    ]

    /// Reads at CALL time, never in a body: the question this fence asks does
    /// not apply to them, and a stock they can never leave would lie about its
    /// aim. Each is exempt for ONE function in ONE file, not for the file,
    /// so a body read added beside it still counts. Each must still stand.
    static let callTimeReads: [(file: String, function: String, reason: String)] = [
        ("PodcastAutoContinue.swift", "next",
         "picks the next episode when one ends"),
        ("PodcastSections.swift", "snapshot",
         "a state snapshot, called only from tasks and async functions"),
        ("PodcastsView.swift", "compute",
         "a change token that is itself a publish path"),
        ("BookDetailScreen.swift", "progressReport",
         "the diagnosis report, built once when the copy button is tapped"),
        ("PodcastHelpers.swift", "run",
         "the automatic download pass of `PodcastAutoDownload`, awaited from the refresh"),
        ("PodcastHelpers.swift", "sweep",
         "the clean-up of finished automatic downloads"),
    ]

    /// The function a line sits in. It walks the chain of enclosing lines,
    /// each indented LESS than the one before, and answers with the first
    /// declaration on it: a `func` gives its name, any other declaration (a
    /// `body`, a computed property, a type) gives `nil`. A sibling function
    /// above never answers, because it is not on the chain.
    static func enclosingFunction(ofLine number: Int, in text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard number >= 1, number <= lines.count else { return nil }
        let indent = { (line: String) in line.prefix { $0 == " " }.count }
        var level = indent(lines[number - 1])
        let otherDeclaration = #"^(?:(?:private|fileprivate|internal|public|static|nonisolated|@\w+)\s+)*(?:var|init|subscript|struct|enum|class|extension)\b"#
        for index in stride(from: number - 2, through: 0, by: -1) {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("//"), indent(line) < level else { continue }
            level = indent(line)
            if let range = trimmed.range(of: #"\bfunc\s+\w+"#, options: .regularExpression) {
                return String(trimmed[range].split(whereSeparator: \.isWhitespace).last ?? "")
            }
            if trimmed.range(of: otherDeclaration, options: .regularExpression) != nil { return nil }
        }
        return nil
    }

    /// The queries that answer from the published state. The published
    /// properties themselves are read from the manager's source, so a new one
    /// is measured without anyone adding it here.
    static let queries = ["isDownloaded", "isDeletableDownload", "isDownloading",
                          "hasPartialDownload", "downloadSize"]

    static func managerSource() throws -> String {
        try String(contentsOf: SourceTree.root.appendingPathComponent(
            "Sources/Networking/DownloadManager.swift"), encoding: .utf8)
    }

    static func publishedProperties(in source: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #"@Published\s+(?:(?:file)?private\(set\)\s+)?var\s+(\w+)"#)
        return regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
            .compactMap { Range($0.range(at: 1), in: source).map { String(source[$0]) } }
    }

    /// Names bound to `DownloadManager.shared` WITHOUT an observation
    /// (`let manager = DownloadManager.shared`, or a computed property that
    /// returns it). A read through such a name is the same unobserved read.
    ///
    /// **Measured, which is why this exists:** the first version searched
    /// the spelling `DownloadManager.shared.member` only, and a red probe that
    /// swapped the book menu's observation for a computed property stayed
    /// green, because the reads then say `downloadManager.member`. The fence
    /// guarded a spelling, not the read.
    static func unobservedAliases(in text: String) throws -> [String] {
        let regex = try NSRegularExpression(
            pattern: #"\b(?:let|var)\s+(\w+)\b[^=\n{]*(?:=|\{)\s*DownloadManager\.shared\b"#)
        var names: [String] = []
        for line in text.split(separator: "\n") {
            let string = String(line)
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"),
                  !ObserverPlaceFenceTests.observationMarkers.contains(where: { string.contains($0) }),
                  let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
                  let range = Range(match.range(at: 1), in: string)
            else { continue }
            names.append(String(string[range]))
        }
        return names
    }

    /// Line numbers where the text reads one of `members` through
    /// `DownloadManager.shared` or through a name bound to it without
    /// observing, outside a comment, and the smallest view around the line
    /// does not observe the manager itself.
    static func unobservedReads(in text: String, members: [String]) throws -> [Int] {
        let holders = [#"DownloadManager\.shared"#] + (try unobservedAliases(in: text)).map { #"\b"# + $0 }
        // Each member is covered by the notifier that carries it: a view that
        // reads progress but observes only the stock is not woken by it.
        var found = Set<Int>()
        for (notifier, group) in Dictionary(grouping: members, by: notifier(for:)) {
            let pattern = "(?:" + holders.joined(separator: "|") + #")\.(?:"#
                + group.joined(separator: "|") + #")\b"#
            found.formUnion(try reads(in: text, matching: pattern, unlessObserving: notifier))
        }
        return found.sorted()
    }

    /// The notifier that publishes a member: progress for the phase and the
    /// question whether a download runs, the stock for everything else.
    static func notifier(for member: String) -> String {
        ["phase", "isDownloading"].contains(member) ? "DownloadManager.progress" : "DownloadManager.stock"
    }

    /// Line numbers where the text matches `pattern` outside a comment and
    /// the smallest view around the line does not observe `publisher`.
    static func reads(in text: String, matching pattern: String,
                      unlessObserving publisher: String) throws -> [Int] {
        let regex = try NSRegularExpression(pattern: pattern)
        let blocks = ObserverPlaceFenceTests.declarations(in: text)
        var found: [Int] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { continue }
            let string = String(line)
            guard regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
            else { continue }
            let number = index + 1
            let holder = blocks
                .filter { $0.firstLine <= number && number <= $0.lastLine }
                .min { ($0.lastLine - $0.firstLine) < ($1.lastLine - $1.firstLine) }
            if let holder, observes(publisher, in: holder.text) { continue }
            found.append(number)
        }
        return found
    }

    static func observes(_ publisher: String, in text: String) -> Bool {
        ObserverPlaceFenceTests.withoutCommentLines(text)
            .split(separator: "\n")
            .contains { line in
                ObserverPlaceFenceTests.observationMarkers.contains { line.contains($0) }
                    && line.contains(publisher)
            }
    }

    /// The premium marking, read through the store's static questions. The
    /// store announces a change of it on its own publisher, so a view that
    /// shows it observes the store itself, or the lock it draws stays as it
    /// was after a marking until something else redraws the view.
    static let premiumPattern = #"PodcastSubscriptions\.(?:isPremiumFeed|isManuallyMarkedPremium)\("#

    /// Premium reads per file, measured. The numbers may only fall.
    ///
    /// Why each one still stands: `PodcastComponents.swift` draws the lock on
    /// the featured card, `RecentShowTile` and `ShowTile`;
    /// `LatestEpisodesGrid.swift` picks the premium episodes for its row.
    /// Each relies on a page above that observes the store; the tiles do not.
    static let premiumStock = [
        "PodcastComponents.swift": 3,
        "LatestEpisodesGrid.swift": 1,
    ]

    @Test("Ansichten lesen den Premium-Status nicht, ohne den Abo-Speicher zu beobachten", .needsTheSources)
    func viewsDoNotReadThePremiumMarkWithoutObserving() throws {
        let files = ProjectFileIntegrityTests.sourceFiles().filter { $0.path.contains("/Sources/Views/") }
        try #require(files.count > 100, "der Zaun hat den Ansichtsbaum nicht gelesen")
        var counts: [String: [Int]] = [:]
        for file in files {
            let lines = try Self.reads(in: String(contentsOf: file, encoding: .utf8),
                                       matching: Self.premiumPattern,
                                       unlessObserving: "PodcastSubscriptions.shared")
            if !lines.isEmpty { counts[file.lastPathComponent] = lines }
        }
        for (name, lines) in counts.sorted(by: { $0.key < $1.key }) {
            let cap = Self.premiumStock[name] ?? 0
            #expect(lines.count <= cap,
                    "\(name) liest den Premium-Status \(lines.count) mal ohne zu beobachten, Bestand ist \(cap): Zeilen \(lines)")
        }
        for name in Self.premiumStock.keys.sorted() {
            #expect(counts[name] != nil, "\(name) steht im Bestand, liest aber nicht mehr: aus der Liste nehmen")
        }
        // The instrument: a tile without observation counts, the show menu,
        // which observes the store, does not.
        let tile = "struct Tile: View {\n    var body: some View {\n        Lock(PodcastSubscriptions.isPremiumFeed(url))\n    }\n}"
        let menu = "struct Menu: View {\n    @ObservedObject private var subs = PodcastSubscriptions.shared\n    var body: some View {\n        if PodcastSubscriptions.isManuallyMarkedPremium(url) { Text(\"x\") }\n    }\n}"
        #expect(try Self.reads(in: tile, matching: Self.premiumPattern, unlessObserving: "PodcastSubscriptions.shared") == [3])
        #expect(try Self.reads(in: menu, matching: Self.premiumPattern, unlessObserving: "PodcastSubscriptions.shared").isEmpty)
    }

    @Test("Ansichten lesen den Download-Zustand nicht, ohne zu beobachten", .needsTheSources)
    func viewsDoNotReadDownloadStateWithoutObserving() throws {
        let published = try Self.publishedProperties(in: Self.managerSource())
        try #require(published.contains("downloadedItemIds"), "der Leser hat den Manager nicht gelesen")
        let members = published + Self.queries
        let files = ProjectFileIntegrityTests.sourceFiles().filter { $0.path.contains("/Sources/Views/") }
        try #require(files.count > 100, "der Zaun hat den Ansichtsbaum nicht gelesen")
        var counts: [String: [Int]] = [:]
        var exemptionsSeen = Set<String>()
        for file in files {
            let name = file.lastPathComponent
            let text = try String(contentsOf: file, encoding: .utf8)
            let lines = try Self.unobservedReads(in: text, members: members).filter { line in
                let function = Self.enclosingFunction(ofLine: line, in: text)
                guard let exemption = Self.callTimeReads.first(where: {
                    $0.file == name && $0.function == function
                }) else { return true }
                exemptionsSeen.insert(exemption.file + "/" + exemption.function)
                return false
            }
            if !lines.isEmpty { counts[name] = lines }
        }
        for exemption in Self.callTimeReads {
            #expect(exemptionsSeen.contains(exemption.file + "/" + exemption.function),
                    "die Ausnahme \(exemption.file) \(exemption.function) liest nicht mehr: aus der Liste nehmen")
        }
        for (name, lines) in counts.sorted(by: { $0.key < $1.key }) {
            let cap = Self.stock[name] ?? 0
            #expect(lines.count <= cap,
                    "\(name) liest den Download-Zustand \(lines.count) mal ohne zu beobachten, Bestand ist \(cap): Zeilen \(lines)")
        }
        for name in Self.stock.keys.sorted() {
            #expect(counts[name] != nil, "\(name) steht im Bestand, liest aber nicht mehr: aus der Liste nehmen")
        }
    }

    /// The instrument, in both directions, and the member list against the
    /// manager's source.
    @Test("der Zaehler sieht die Lesung, und nur die ohne Beobachtung")
    func theCounterSeesTheReadAndOnlyTheUnobservedOne() throws {
        let members = ["isDownloaded", "phase"]
        let bare = """
        struct Row: View {
            var body: some View {
                Text(DownloadManager.shared.isDownloaded(itemId: id) ? "a" : "b")
            }
        }
        """
        #expect(try Self.unobservedReads(in: bare, members: members) == [3])
        let observing = """
        struct Row: View {
            @ObservedObject private var downloadStock = DownloadManager.stock
            var body: some View {
                Text(DownloadManager.shared.isDownloaded(itemId: id) ? "a" : "b")
            }
        }
        """
        #expect(try Self.unobservedReads(in: observing, members: members).isEmpty)
        // Observing the wrong notifier is not observing: the stock does not
        // wake a view for progress.
        let wrongNotifier = """
        struct Row: View {
            @ObservedObject private var downloadStock = DownloadManager.stock
            var body: some View {
                if DownloadManager.shared.phase[id] != nil { Text("a") }
            }
        }
        """
        #expect(try Self.unobservedReads(in: wrongNotifier, members: members) == [4],
                "der Fortschritt wird nur vom Fortschritts-Melder gedeckt")
        let actionAndComment = """
        struct Row: View {
            var body: some View {
                // DownloadManager.shared.isDownloaded used to be read here
                Button("x") { DownloadManager.shared.deleteDownload(itemId: id) }
            }
        }
        """
        #expect(try Self.unobservedReads(in: actionAndComment, members: members).isEmpty,
                "eine Handlung und ein Kommentar sind keine Lesung")
        #expect(try Self.unobservedReads(in: "let p = DownloadManager.shared.phase[id]", members: members) == [1],
                "ausserhalb jeder Ansicht zaehlt die Lesung auch")
        let aliased = """
        struct Menu: View {
            private var downloads: DownloadManager { DownloadManager.shared }
            private let held = DownloadManager.shared
            var body: some View {
                if downloads.isDownloaded(itemId: id) { Text("a") }
                if held.phase[id] != nil { Text("b") }
            }
        }
        """
        #expect(try Self.unobservedReads(in: aliased, members: members) == [5, 6],
                "ein Name fuer den Manager ohne Beobachtung ist dieselbe Lesung")

        // The exemption is local: a function gives its name, a body or a
        // computed property below a sibling function gives none.
        let placed = """
        struct Page: View {
            static func compute() -> String {
                let token = DownloadManager.shared.downloadedItemIds
                return "\\(token)"
            }
            private var badge: Bool {
                DownloadManager.shared.isDownloaded(itemId: id)
            }
            var body: some View {
                Text(DownloadManager.shared.isDownloaded(itemId: id) ? "a" : "b")
            }
        }
        """
        #expect(Self.enclosingFunction(ofLine: 3, in: placed) == "compute")
        #expect(Self.enclosingFunction(ofLine: 7, in: placed) == nil,
                "eine berechnete Eigenschaft unter einer Funktion gehoert nicht zur Funktion")
        #expect(Self.enclosingFunction(ofLine: 10, in: placed) == nil)

        // The member list: every published property is measured, and every
        // listed query exists, or the list would guard a name nobody has.
        let source = try Self.managerSource()
        #expect(Set(try Self.publishedProperties(in: source))
                    .isSuperset(of: ["downloadedItemIds", "phase", "totalDownloadsSize", "sizeByItem"]),
                "der Leser findet die vier gemeldeten Eigenschaften der zwei Melder, die es heute gibt")
        for query in Self.queries {
            #expect(source.contains("func \(query)("), "die Abfrage \(query) gibt es im Manager nicht")
        }
    }
}
#endif
