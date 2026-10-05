// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The rows page: every switchable row says what it draws from or shows,
/// one class carries one name, the second lines stand beside the switch,
/// and the logo diagnosis is no control for the person.
struct AppRowsPageTests {
    @Test("jede schaltbare Reihe hat eine Unterzeile")
    func everySwitchableRowHasASecondLine() {
        for configured in [false, true] {
            let without = AppRows.all.filter {
                $0.toggleable && (AppRows.subline($0, podcastIndexConfigured: configured) ?? "").isEmpty
            }.map(\.key)
            #expect(without.isEmpty, "rows without a second line: \(without)")
        }
    }

    @Test("der Katalog der Hoerbuecher und Hoerspiele heisst am Start und im Reiter gleich")
    func theCatalogCarriesOneName() throws {
        let home = try #require(AppRows.row(key: "home.discoverBooks"))
        let books = try #require(AppRows.row(key: "books.catalog"))
        #expect(home.title.hasSuffix(books.title), "\(home.title) and \(books.title) name one class twice")
    }

    @Test("die Unterzeilen stehen im Label des Schalters, in einem Grau", .needsTheSources)
    func theSecondLinesStandBesideTheSwitch() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/RowsSettingsView.swift"), encoding: .utf8))
        // The switch, then its label with the lines, then the modifier on
        // the switch: the lines are inside the switch's label.
        let toggle = try #require(code.range(of: "AppSwitch(isOn: Binding("), "the switch moved")
        let lines = try #require(code.range(of: "lines", range: toggle.upperBound..<code.endIndex))
        let identifier = try #require(code.range(of: ".accessibilityIdentifier(\"row-toggle-"))
        #expect(lines.upperBound <= identifier.lowerBound, "the second lines left the switch's label")
        #expect(!code.contains(".tertiary"), "a second line in the grey that measured 1.7 to 1")
    }

    @Test("ein Schalter, ein Wert: kein Schluessel schaltet zwei Reihen")
    func oneSwitchOneValue() {
        let keys = AppRows.all.compactMap(\.storageKey)
        let shared = Dictionary(grouping: keys, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        #expect(shared.isEmpty, "one key switches several rows: \(shared)")
        #expect(AppRows.row(key: "home.rediscover")?.storageKey == AppStorageKeys.rowHomeRediscoverVisible,
                "Rediscover hangs on another row's switch")
    }

    @Test("ein neuer Reihen-Schluessel beginnt einmal mit der alten Wahl")
    func aNewRowKeyStartsFromTheOldChoice() throws {
        let suite = "rows-carry-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: AppStorageKeys.freeAudiobooksEnabled)
        AppRows.carryOldChoices(defaults: defaults)
        #expect(defaults.object(forKey: AppStorageKeys.rowHomeDiscoverBooksVisible) as? Bool == false, "the old off was lost")
        #expect(defaults.object(forKey: AppStorageKeys.rowHomeRediscoverVisible) == nil, "a key whose old one was never set stays unset")
        defaults.set(true, forKey: AppStorageKeys.rowHomeDiscoverBooksVisible)
        AppRows.carryOldChoices(defaults: defaults)
        #expect(defaults.object(forKey: AppStorageKeys.rowHomeDiscoverBooksVisible) as? Bool == true, "a set key was overwritten")
    }

    @Test("jede Reihe hat einen Schreibweg, und Start-Klassik folgt ihrer eigenen Reihe", .needsTheSources)
    func oneWritePathAndTheClassicalHalfFollowsItsRow() throws {
        let settings = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/SettingsView.swift"), encoding: .utf8))
        #expect(!settings.contains("isOn: $homeRecommendations"), "a second switch writes the row past the cleanup rule")
        #expect(settings.contains("AppRows.setVisible(row, newValue)"))
        let keys = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Models/AppStorageKeys.swift"), encoding: .utf8))
        let classical = try #require(functionBody(of: "static var freeClassicalActive: Bool {", in: keys))
        #expect(classical.contains("home.discoverMusic") && !classical.contains("shellac"),
                "the classical half of Start hangs on the music tab's old records")
        let home = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/HomeView.swift"), encoding: .utf8))
        #expect(home.contains("if rediscoverRowVisible { rediscoverSection }"))
    }

    @Test("beide Empfohlen nennen jede Quelle, die ihr Vorrat fragen kann", .needsTheSources)
    func bothRecommendedRowsNameEveryDirectory() throws {
        let store = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Providers/PodcastRecommendationsStore.swift"), encoding: .utf8))
        #expect(store.contains("PodcastDirectorySelection.directory()"), "the pool left the one selection")
        for key in ["home.recommendations", "podcasts.recommended"] {
            let row = try #require(AppRows.row(key: key))
            #expect(Set(row.sourceKeys) == ["appleCatalog", "podcastIndex"], "\(key) declares \(row.sourceKeys)")
        }
        let row = try #require(AppRows.row(key: "podcasts.recommended"))
        // Without a key PodcastIndex is never asked, so the lines leave it out.
        let without = try #require(AppRows.subline(row, podcastIndexConfigured: false))
        let with = try #require(AppRows.subline(row, podcastIndexConfigured: true))
        #expect(without.contains("Apple Podcasts") && !without.contains("Podcast Index"), "\(without)")
        #expect(with.contains("Apple Podcasts") && with.contains("Podcast Index"), "\(with)")
        #expect(AppRows.unsourcedTitles(row, podcastIndexConfigured: false, isAllowed: { $0 == "podcastIndex" })
                == ["Apple Podcasts"], "a source without a key carried the row")
        #expect(AppRows.unsourcedTitles(row, podcastIndexConfigured: true, isAllowed: { $0 == "podcastIndex" }) == nil)
    }

    @Test("ohne Anmeldung haelt der Schalter des Katalogs die eingebettete Seite", .needsTheSources)
    func theEmbeddedCatalogFollowsTheRowSwitch() throws {
        let code = Self.squeezed(SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/LibraryView.swift"), encoding: .utf8)))
        #expect(code.components(separatedBy: "embedded:true").count == 2, "a second embedded catalog page")
        #expect(code.contains("ifcatalogRowVisible{FreeAudiobooksPage(playerCoordinator:playerCoordinator,embedded:true)"),
                "the page without sign in stands past the row switch")
        #expect(code.contains("@AppStorage(AppStorageKeys.freeAudiobooksEnabled)privatevarcatalogRowVisible"))
    }

    /// Code with every whitespace removed, for a shape that spans lines.
    nonisolated static func squeezed(_ code: String) -> String {
        code.filter { !$0.isWhitespace }
    }

    @Test("die Logo-Diagnose steht nur im Entwicklungsbau", .needsTheSources)
    func theLogoDiagnosisIsDebugOnly() throws {
        let code = try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Radio/RadioView.swift"), encoding: .utf8)
        #expect(Self.namesOutsideDebug("logoDiagnosisSection", in: code) == 0, "the diagnosis reaches a release build")
        #expect(Self.namesOutsideDebug("x", in: "#if DEBUG\nx\n#endif\nx") == 1)
    }

    /// Lines naming `token` that stand outside an `#if DEBUG` block.
    nonisolated static func namesOutsideDebug(_ token: String, in code: String) -> Int {
        var depth = 0
        var count = 0
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if DEBUG") { depth += 1; continue }
            if trimmed.hasPrefix("#endif"), depth > 0 { depth -= 1; continue }
            if depth == 0, !trimmed.hasPrefix("//"), trimmed.contains(token) { count += 1 }
        }
        return count
    }
}
#endif
