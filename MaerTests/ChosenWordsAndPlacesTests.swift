// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The chosen form of several surfaces: a damaged held key asks like a
/// changed one, the sentences of an unreadable key, the folder sheet's
/// short values and its title, the line of a folder that plays all unheard,
/// and a place in the settings for the suggested folders.
@MainActor
struct ChosenWordsAndPlacesTests {
    static func code(_ path: String) throws -> String {
        SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
    }

    @Test("a damaged held key asks like a changed one, with not readable as the held side; accepting the offered holds it; an unreadable one still stops")
    func damagedKeyAsks() {
        #expect(ServiceKeyTrust.meeting(pin: .damaged, offered: "K", accepting: nil) == .ask(held: ServiceKeyTrust.unreadableHeld, offered: "K"))
        #expect(ServiceKeyTrust.meeting(pin: .damaged, offered: "K", accepting: "K") == .hold("K"))
        #expect(ServiceKeyTrust.meeting(pin: .unreadable, offered: "K", accepting: "K") == .stopUnreadable)
        #expect(ServiceKeyTrust.meeting(pin: .held("H"), offered: "K", accepting: nil) == .ask(held: "H", offered: "K"))
        #expect(ServiceKeyTrust.meeting(pin: .held("K"), offered: "K", accepting: nil) == .proceed)
        #expect(ServiceKeyTrust.meeting(pin: .none, offered: "K", accepting: nil) == .hold("K"))
    }

    @Test("Fence: the sign-in asks the rule, and the page names an unreadable held key in words", .needsTheSources)
    func signInAsksTheRule() throws {
        #expect(try Self.code("Sources/Networking/MaerSyncSignIn.swift").contains("ServiceKeyTrust.meeting(pin:"))
        let page = try Self.code("Sources/Views/MaerSyncSettingsView.swift")
        #expect(page.contains("change.held == ServiceKeyTrust.unreadableHeld"))
        #expect(page.contains("Text(\"The stored key cannot be read right now.\")"))
        #expect(page.contains("String(localized: \"The stored key of this service cannot be read right now. Try again in a moment. Your password was not sent.\")"))
        #expect(!page.contains("The held key cannot be read right now."))
    }

    @Test("Fence: the folder sheet offers short values and carries the folder's name as its title; the suggestions sheet a short one", .needsTheSources)
    func folderSheet() throws {
        let sheet = try Self.code("Sources/Views/Podcasts/AddShowToFolderSheet.swift")
        #expect(sheet.contains("Text(\"Newest per show\")") && sheet.contains("Text(\"All unheard\")"))
        #expect(sheet.contains("if let editing { return Text(verbatim: editing.name) }"))
        #expect(try Self.code("Sources/Views/Podcasts/SmartFolderSheet.swift").contains(".navigationTitle(Text(\"Suggestions\"))"))
    }

    @Test("a folder that plays all unheard says so under its play")
    func allUnheardLine() {
        #expect(PodcastFolderPlay.line(for: .allUnheard) == String(localized: "Plays every unheard episode, oldest first."))
    }

    @Test("the preview of suggested folders opens from the settings with any suggestion, whatever the count of subscriptions")
    func previewFromTheSettings() {
        #expect(SmartFolderSuggestion.offersPreview(suggestions: 1))
        #expect(!SmartFolderSuggestion.offersPreview(suggestions: 0))
    }

    @Test("Fence: the podcast settings carry the switch of the hint and the way to the preview, on the one key of the hint", .needsTheSources)
    func settingsPlace() throws {
        let section = try Self.code("Sources/Views/Podcasts/SmartFolderSettingsSection.swift")
        #expect(section.contains("@AppStorage(AppStorageKeys.smartFoldersHintDismissed) private var hintDismissed"))
        #expect(section.contains("Toggle(isOn: Binding(get: { !hintDismissed }, set: { hintDismissed = !$0 }))") || section.contains("AppSwitch(isOn: Binding(get: { !hintDismissed }, set: { hintDismissed = !$0 }))"))
        #expect(section.contains("SmartFolderSheet("))
        #expect(try Self.code("Sources/Views/SettingsView.swift").contains("SmartFolderSettingsSection("))
    }
}
#endif
