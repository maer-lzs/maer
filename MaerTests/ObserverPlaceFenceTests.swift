// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Observations of a frequently publishing singleton belong in the smallest
/// leaf that shows the value, never in a container that carries scroll
/// content: the container's body then re-runs on every publish.
///
/// **Measured, which is why this is a fence and not a habit.** Two shapes
/// were put under the same publisher on the real runtime and driven ten
/// times: the observing container ran ten times, the plain one zero. The
/// measurement lives in the deliveries channel as a tool, not here, because
/// it measures SwiftUI rather than this app and would stay green whatever we
/// build.
///
/// **What this fence measures instead is the shape we reached**, per view and
/// not per file. A file can hold a container and a leaf at once, and two of
/// the sites that looked wrong at file level are leaves.
struct ObserverPlaceFenceTests {
    /// The singletons whose publishes are frequent enough for the place to
    /// matter. Each carries its measured stock: the number of observations
    /// that still sit in a view carrying scroll content.
    ///
    /// **The numbers may only fall, and every slice writes back the MEASURED
    /// value.** A cap that is not written back stops being one; the growth
    /// fence beside this one records what that costs.
    ///
    /// **The downloader publishes through two notifiers.** The three
    /// containers that observe it (the two download pages, which ARE the
    /// downloaded set, and the library's download row) observe the STOCK,
    /// which changes when a download finishes or leaves, never on a progress
    /// step; the progress notifier sits in no container. Measured on one
    /// download of 100 steps: the stock notifies 3 times, the progress 102,
    /// where the single notifier before woke everyone 104 times.
    static let stock = ["DownloadStock": 3, "DownloadProgress": 0, "PodcastSubscriptions": 10, "ABSPodcastProvider": 3]
    /// How an observation of a publisher is spelled where it is not
    /// `<Name>.shared`: the downloader's two notifiers are reached through it.
    static let spelling = ["DownloadStock": "DownloadManager.stock", "DownloadProgress": "DownloadManager.progress"]

    static let observationMarkers = ["@ObservedObject", "@StateObject",
                                     "@EnvironmentObject", "@Bindable"]

    /// The invariant speaks of SCROLL content, so that is what is measured,
    /// and nothing wider: a long stack of rows is a container in spirit but
    /// not by this rule, and calling it one here would be a claim the number
    /// does not carry.
    ///
    /// **The list itself is measured, not trusted**, because the whole number
    /// hangs on it. Counted in the tree without comment lines: `ScrollView`
    /// 95, `LazyVStack` 31, `LazyHStack` 30, `Form` 30, `List` 42 in its two
    /// spellings, `LazyVGrid` 17. A second reader counted seven instead of
    /// eight because `Form` was missing from his list, which is how the size
    /// of that hole became visible.
    ///
    /// **Three entries occur zero times today** and stay in so a first use is
    /// caught rather than welcomed: `LazyHGrid` and the two spellings of the
    /// PAGE tab style. **The page style, not `TabView` itself**: a tab
    /// switcher does not scroll, a paged one does, and a marker wider than
    /// the rule would make containers out of leaves.
    ///
    /// **`Grid` and `ForEach` are deliberately OUT** although they are
    /// frequent (42 and 189): neither scrolls. Measured as absent from the
    /// whole of `Sources` as well: `TabView`, `Table`, `NavigationSplitView`.
    /// `ScrollViewReader` stands in three files and always around a
    /// `ScrollView`, so it would only count what is already counted.
    static let scrollMarkers = ["ScrollView", "List(", "List {", "LazyVGrid", "LazyHGrid",
                                "LazyVStack", "LazyHStack", "Form(", "Form {",
                                "PageTabViewStyle", ".tabViewStyle(.page"]

    /// One view declaration with its extent. `ViewModifier` counts as a view:
    /// it owns a body and re-runs with it, and one of the observations in
    /// this tree sits in one.
    struct Declaration {
        let name: String
        let firstLine: Int
        let lastLine: Int
        let text: String
    }

    static func declarations(in text: String) -> [Declaration] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var found: [Declaration] = []
        var index = 0
        while index < lines.count {
            guard let name = declaredViewName(in: lines[index]) else {
                index += 1
                continue
            }
            var depth = 0
            var started = false
            var end = index
            while end < lines.count {
                depth += lines[end].filter { $0 == "{" }.count
                depth -= lines[end].filter { $0 == "}" }.count
                if lines[end].contains("{") { started = true }
                if started && depth <= 0 { break }
                end += 1
            }
            let last = min(end, lines.count - 1)
            found.append(Declaration(name: name, firstLine: index + 1, lastLine: last + 1,
                                     text: lines[index...last].joined(separator: "\n")))
            index = last + 1
        }
        return found
    }

    /// `struct Name: View`, `struct Name<T>: SomeProtocol, View`, and the
    /// same for `ViewModifier`. The generic list has to be skipped or two
    /// declarations in this tree stay invisible, and an invisible declaration
    /// means its observation is counted nowhere.
    static func declaredViewName(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // A commented-out declaration is none. Without this the reader would
        // open a block that never closes and swallow every observation below
        // it, which is the silent-zero failure this fence must not have.
        guard !trimmed.hasPrefix("//") else { return nil }
        guard trimmed.contains("struct "), trimmed.contains("{"),
              let structRange = trimmed.range(of: "struct ") else { return nil }
        let afterStruct = trimmed[structRange.upperBound...]
        let name = String(afterStruct.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
        guard !name.isEmpty else { return nil }
        guard let colon = afterStruct.firstIndex(of: ":"),
              let brace = afterStruct.firstIndex(of: "{"), colon < brace else { return nil }
        let conformances = afterStruct[afterStruct.index(after: colon)..<brace]
        let words = conformances.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard words.contains("View") || words.contains("ViewModifier") else { return nil }
        return name
    }

    /// The text without whole comment lines. A sentence ABOUT a list is not a
    /// list, and this gap has spoiled a number in this suite before.
    static func withoutCommentLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    static func carriesScrollContent(_ text: String) -> Bool {
        let code = withoutCommentLines(text)
        return scrollMarkers.contains { code.contains($0) }
    }

    /// Every observation with the smallest view that declares it.
    static func misplaced() throws -> [String: [String]] {
        var offenders: [String: [String]] = [:]
        var unresolved: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles()
        where file.path.contains("/Sources/Views/") {
            let text = try String(contentsOf: file, encoding: .utf8)
            let blocks = declarations(in: text)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"),
                      observationMarkers.contains(where: { trimmed.contains($0) })
                else { continue }
                for name in stock.keys where trimmed.contains(spelling[name] ?? name + ".shared") {
                    let lineNumber = number + 1
                    let holders = blocks.filter { $0.firstLine <= lineNumber && lineNumber <= $0.lastLine }
                    guard let holder = holders.min(by: { ($0.lastLine - $0.firstLine) < ($1.lastLine - $1.firstLine) })
                    else {
                        unresolved.append("\(file.lastPathComponent):\(lineNumber) \(name)")
                        continue
                    }
                    if carriesScrollContent(holder.text) {
                        offenders[name, default: []].append(
                            "\(file.lastPathComponent):\(lineNumber) in \(holder.name)")
                    }
                }
            }
        }
        // An observation the reader cannot place is counted NOWHERE, so it
        // would silently leave the stock. That is the failure this fence must
        // not have, and it is the reason the reader knows generics.
        #expect(unresolved.isEmpty, "der Leser findet die Ansicht nicht: \(unresolved)")
        return offenders
    }

    @Test("Beobachtungen haeufiger Melder sitzen nicht in rollenden Containern", .needsTheSources)
    func frequentPublishersAreNotObservedInScrollingContainers() throws {
        let files = ProjectFileIntegrityTests.sourceFiles().filter { $0.path.contains("/Sources/Views/") }
        try #require(files.count > 100, "der Zaun hat den Ansichtsbaum nicht gelesen")
        let offenders = try Self.misplaced()
        for (name, cap) in Self.stock.sorted(by: { $0.key < $1.key }) {
            let found = offenders[name] ?? []
            #expect(found.count <= cap,
                    "\(name) wird an \(found.count) falschen Orten beobachtet, Bestand ist \(cap): \(found)")
        }
    }

    /// The reader itself, in both directions. Without this the fence could
    /// answer zero in silence, and a stock of zero would look like success.
    @Test("der Leser findet die Ansicht, auch generisch und als Modifier")
    func theReaderFindsTheView() {
        #expect(Self.declaredViewName(in: "struct Plain: View {") == "Plain")
        #expect(Self.declaredViewName(in: "private struct Scope<Content: View>: View {") == "Scope")
        #expect(Self.declaredViewName(in: "private struct Menu: ViewModifier {") == "Menu")
        #expect(Self.declaredViewName(in: "struct Rules: Equatable {") == nil)
        #expect(Self.declaredViewName(in: "// struct Commented: View {") == nil,
                "eine auskommentierte Deklaration ist keine")
        // EVERY marker gets its own witness. Without this the number hangs on
        // an unchecked list, and one missing entry moves it: a second reader
        // counted seven instead of eight because his list had no `Form`.
        for marker in Self.scrollMarkers {
            #expect(Self.carriesScrollContent("var body: some View { \(marker) Text(\"x\") } }"),
                    "der Rolltraeger \(marker) wird nicht erkannt")
        }
        #expect(Self.carriesScrollContent("var body: some View { Form { Toggle(\"x\", isOn: $on) } }"),
                "eine Einstellungsseite traegt ihre Zeilen in einer Form, und die rollt")
        #expect(!Self.carriesScrollContent("// the ScrollView used to live here\nvar body: some View { Text(\"x\") }"),
                "ein Satz UEBER eine Liste ist keine Liste")
        #expect(!Self.carriesScrollContent("var body: some View { VStack { Text(\"x\") } }"))
        // The two frequent neighbours that stay out, with their reason: they
        // lay out, they do not scroll.
        #expect(!Self.carriesScrollContent("var body: some View { Grid { GridRow { Text(\"x\") } } }"))
        #expect(!Self.carriesScrollContent("var body: some View { ForEach(items) { Text($0.name) } }"))
    }
}
#endif
