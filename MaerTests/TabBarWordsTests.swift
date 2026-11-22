// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The words of the tab bar: a tab shows its word when the word fits whole,
/// the text is below the accessibility sizes and the switch under General
/// is on (on by default, per device); in landscape the word stands beside
/// the symbol. Otherwise the symbol alone, larger. Every tab keeps its name
/// for VoiceOver and shows it large on a long press.
struct TabBarWordsTests {
    @Test("a word stands when it fits, the text is small enough and the switch is on; beside the symbol in landscape")
    func form() {
        #expect(TabBarWords.form(wordFits: true, accessibilitySize: false, wordsOn: true, landscape: false) == .wordBelow)
        #expect(TabBarWords.form(wordFits: true, accessibilitySize: false, wordsOn: true, landscape: true) == .wordBeside)
        #expect(TabBarWords.form(wordFits: false, accessibilitySize: false, wordsOn: true, landscape: false) == .symbol)
        #expect(TabBarWords.form(wordFits: true, accessibilitySize: true, wordsOn: true, landscape: false) == .symbol)
        #expect(TabBarWords.form(wordFits: true, accessibilitySize: false, wordsOn: false, landscape: false) == .symbol)
        #expect(TabBarWords.form(wordFits: true, accessibilitySize: false, wordsOn: false, landscape: true) == .symbol)
    }

    @Test("the bar offers the word sizes first and the symbols last; without words only the symbols")
    func rungs() {
        let sizes: [CGFloat] = [11, 10, 9]
        #expect(TabBarWords.rungs(sizes, accessibilitySize: false, wordsOn: true) == [11, 10, 9, TabBarWords.symbolRung])
        #expect(TabBarWords.rungs(sizes, accessibilitySize: true, wordsOn: true) == [TabBarWords.symbolRung])
        #expect(TabBarWords.rungs(sizes, accessibilitySize: false, wordsOn: false) == [TabBarWords.symbolRung])
    }

    @Test("the switch is on by default and stays on its device")
    func theSwitch() {
        #expect(TabBarWords.defaultOn)
        #expect(UserChoiceCatalog.statics[AppStorageKeys.tabBarWords] == .device)
    }

    @Test("General carries the switch, the bar reads it, and every tab keeps its name for VoiceOver and the large content viewer", .needsTheSources)
    func surfaces() throws {
        let settings = try SourceTree.text(SourceTree.root.appendingPathComponent("Sources/Views/SettingsView.swift"))
        #expect(settings.contains("@AppStorage(AppStorageKeys.tabBarWords) private var tabBarWords = TabBarWords.defaultOn"),
                "General has no switch for the words")
        let bar = try SourceTree.text(SourceTree.root.appendingPathComponent("Sources/Views/MediaTabBar.swift"))
        #expect(bar.contains("@AppStorage(AppStorageKeys.tabBarWords)"), "the bar does not read the switch")
        #expect(bar.contains("TabBarWords.rungs("), "the bar does not ask the rule")
        #expect(bar.contains(".accessibilityLabel(Text(cell.label))"), "a tab lost its name for VoiceOver")
        #expect(bar.contains(".accessibilityShowsLargeContentViewer"), "a long press does not show the tab large")
    }
}
#endif
