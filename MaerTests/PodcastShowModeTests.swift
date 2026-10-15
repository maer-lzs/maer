// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
import SwiftUI
@testable import Maer

/// Eine Sendungsseite, zwei Zustaende. Die Zaeune halten die Grenze fest:
/// Ansehen schreibt nichts, Abspielen schreibt genau einen Hoerstand, und die
/// Sperren sind Konstruktion statt Sichtpruefung.
struct PodcastShowModeTests {

    // MARK: - Ansehen schreibt nichts

    /// Der Kern der Auflage: eine nicht abonnierte Sendung anzusehen, ihre
    /// Liste zu zeichnen und zu sortieren, laesst den Speicher byte-gleich.
    /// Der Zaun sitzt an der EINEN Schreibstelle, nicht an der Ansicht, damit
    /// eine spaeter hinzugefuegte Aufrufstelle ihn nicht umgehen kann.
    @Test("looking at a show writes nothing, subscribing to it remembers")
    func browsingLeavesTheStoreUntouched() throws {
        let suite = "showmode-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let showId = "rss:https://example.org/feed.xml"
        var prefs = PodcastShowPreferences.default
        prefs.newestFirst = false
        prefs.unplayedOnly = true

        prefs.save(showId: showId, mode: .browsed, defaults: defaults)
        #expect(defaults.object(forKey: PodcastShowPreferences.sortKey(showId: showId)) == nil,
                "das Ansehen hat einen Sortier-Zustand hinterlassen")
        #expect(defaults.object(forKey: PodcastShowPreferences.filterKey(showId: showId)) == nil,
                "das Ansehen hat einen Filter-Zustand hinterlassen")

        // Rot-Probe am Instrument: derselbe Aufruf im abonnierten Zustand
        // schreibt sehr wohl. Ein Zaun, der nie etwas sieht, beweist nichts.
        prefs.save(showId: showId, mode: .subscribed, defaults: defaults)
        #expect(defaults.object(forKey: PodcastShowPreferences.sortKey(showId: showId)) as? Bool == false)
        #expect(defaults.object(forKey: PodcastShowPreferences.filterKey(showId: showId)) as? Bool == true)
    }

    /// Eine angesehene Sendung faengt bei der Vorgabe an, auch wenn unter
    /// ihrer Kennung noch alte Schluessel liegen. Sonst haette ein frueheres
    /// Abo einen unsichtbaren Filter in die neue Ansicht getragen.
    @Test("a browsed show starts from the default, whatever lies under its id")
    func browsedPreferencesIgnoreOldKeys() throws {
        let suite = "showmode-load-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let showId = "rss:https://example.org/feed.xml"
        defaults.set(false, forKey: PodcastShowPreferences.sortKey(showId: showId))
        defaults.set(true, forKey: PodcastShowPreferences.filterKey(showId: showId))

        #expect(PodcastShowPreferences.load(showId: showId, mode: .browsed, defaults: defaults)
                == .default)
        #expect(PodcastShowPreferences.load(showId: showId, mode: .subscribed, defaults: defaults)
                == PodcastShowPreferences(newestFirst: false, unplayedOnly: true))
    }

    // MARK: - Die Sperren sind Konstruktion

    /// Was das Abo wirklich unterscheidet, steht als Wert da. Die Ansicht
    /// fragt ihn, statt an vier Stellen `if subscribed` zu schreiben.
    @Test("the state carries the abilities; the browsed state has none of them but the history for the visit")
    func capabilitiesFollowTheState() {
        let subscribed = PodcastShowCapabilities.of(.subscribed)
        let browsed = PodcastShowCapabilities.of(.browsed)

        #expect(subscribed.managesSubscription && !browsed.managesSubscription)
        #expect(subscribed.showsSettingsSheet && !browsed.showsSettingsSheet)
        #expect(subscribed.remembersPreferences && !browsed.remembersPreferences)
        #expect(subscribed.downloads && !browsed.downloads)
        // The full history of a browsed show is held for the visit and
        // stores nothing, so the button stands on it too.
        #expect(subscribed.fetchesMoreEpisodes && browsed.fetchesMoreEpisodes)
        #expect(subscribed.marksAllEpisodes && !browsed.marksAllEpisodes)
    }

    // MARK: - Es gibt nur noch eine Sendungsseite

    /// Die zweite Sendungsseite ist weg, und die Route fuehrt beide Zustaende
    /// auf dieselbe Ansicht. Ohne diesen Zaun kaeme die Vorschau als
    /// Sonderfall zurueck, und die beiden Flaechen drifteten wieder.
    @Test("there is one show page, and the route leads both states to it", .needsTheSources)
    func oneShowPageOnly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        var names: [String] = []
        for url in SourceTree.files(under: sources) where url.pathExtension == "swift" {
            names.append(url.lastPathComponent)
        }
        #expect(!names.isEmpty, "der Zaun hat keine Quelldatei gelesen, also misst er nichts")
        #expect(!names.contains("PodcastShowPreviewView.swift"),
                "die zweite Sendungsseite ist zurueck")

        let navigation = try String(
            contentsOf: sources.appendingPathComponent("Views/Podcasts/PodcastNavigation.swift"),
            encoding: .utf8)
        #expect(!navigation.contains("showPreview"),
                "die Vorschau-Route ist zurueck")
        #expect(navigation.contains("PodcastShowView(feedURL:"),
                "die Route fuehrt einen nicht abonnierten Feed nicht mehr auf die Seite")
    }

    /// Der Abo-Zustand darf nicht am LADEZUSTAND der Speicher haengen. Die
    /// Speicher fuellen sich nebenlaeufig; eine Seite, die waehrend eines
    /// Kaltstarts geoeffnet wird, findet sie leer. Wer die Sendung als WERT
    /// hereinreicht, hat sie aus einem Speicher, und damit endet die Suche.
    /// Sonst boete die Seite an, eine bereits abonnierte Sendung zu
    /// abonnieren, und das ist genau die Abnahme-Marke.
    @Test("a show handed in by value ends the lookup, so a cold open stays subscribed", .needsTheSources)
    func aSeededShowCountsAsSubscribed() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let page = try String(
            contentsOf: root.appendingPathComponent("Sources/Views/Podcasts/PodcastShowView.swift"),
            encoding: .utf8)
        let body = try #require(functionBody(of: "private var storedShow: PodcastShow? {", in: page))
        #expect(body.contains("return seedShow"),
                "die Suche endet nicht mehr beim hereingereichten Wert")
        #expect(!body.contains("return nil"),
                "die Suche kann wieder leer ausgehen, obwohl eine Sendung hereingereicht wurde")
    }

    /// Der Download-Knopf ist im angesehenen Zustand ABWESEND, nicht
    /// abgeschaltet. Die Seite loest die Faehigkeit einmal auf und reicht sie
    /// hinunter, wie die Herkunfts-Kapsel.
    @Test("the row asks for the download ability instead of deciding itself", .needsTheSources)
    func theRowIsHandedItsDownloadAbility() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let components = try String(
            contentsOf: root.appendingPathComponent("Sources/Views/Podcasts/PodcastComponents.swift"),
            encoding: .utf8)
        #expect(components.contains("var showsDownload: Bool"),
                "die Zeile entscheidet wieder selbst ueber den Download")
        let page = try String(
            contentsOf: root.appendingPathComponent("Sources/Views/Podcasts/PodcastShowView.swift"),
            encoding: .utf8)
        #expect(page.contains("showsDownload: caps.downloads"),
                "die Seite reicht die Faehigkeit nicht mehr hinunter")
    }

    // MARK: - Von Hand als gehoert markieren

    /// Markieren ist eine Aussage ueber das eigene Hoeren und gehoert damit in
    /// dieselbe Familie wie ein Hoerstand, auch ohne Abo. Es schreibt die
    /// Endposition ueber die dritte Schreibstelle, und die trug die Regel
    /// nicht: ohne sie ueberlebt die Position ihre Aufloesung, und die Kachel
    /// traegt keinen Namen.
    @Test("marking a browsed episode by hand keeps it resolvable, a tombstone does not")
    func markingByHandKeepsTheEpisodeResolvable() throws {
        let suite = "showmode-mark-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let feed = "https://example.org/mark.xml"
        let heard = "rss:\(feed):heard"
        let untouched = "rss:\(feed):untouched"
        let show = PodcastShow(
            id: "rss:\(feed)", title: "Eine Sendung", author: nil, artworkURL: nil,
            description: nil, feedURL: feed,
            episodes: [
                PodcastEpisode(guid: heard, title: "Erste Folge",
                               audioURL: "https://example.org/1.mp3",
                               pubDate: 0, duration: 1800, description: nil, imageURL: nil,
                               chaptersURL: nil),
                PodcastEpisode(guid: untouched, title: "Zweite Folge",
                               audioURL: "https://example.org/2.mp3",
                               pubDate: 0, duration: 1800, description: nil, imageURL: nil,
                               chaptersURL: nil)
            ])
        BrowsedEpisodes.shared.remember(show: show)
        defer { BrowsedEpisodes.shared.forget(showId: show.id) }

        ListeningStore.store(heard,
                             entry: ProgressMark.entry(position: 1800, duration: 1800,
                                                       nowMs: 1_000),
                             in: defaults)
        let kept = try #require(BrowsedEpisodes.shared.listened(guid: heard, defaults: defaults),
                                "die von Hand markierte Folge ist nicht mehr aufloesbar")
        #expect(kept.episodeTitle == "Erste Folge")

        // Rot-Probe: der Ungehoert-Vermerk sagt das Gegenteil und schreibt
        // deshalb nichts nieder. Ohne sie meldete eine Schreibstelle, die JEDE
        // Kennung niederschreibt, genauso gruen.
        ListeningStore.store(untouched,
                             entry: ProgressMark.entry(position: 0, duration: 0, nowMs: 1_000),
                             in: defaults)
        #expect(BrowsedEpisodes.shared.listened(guid: untouched, defaults: defaults) == nil,
                "der Ungehoert-Vermerk schreibt die Folge nieder")
    }

    // MARK: - Ein 404 wegen fehlendem Abo vermerkt nichts als weg

    /// Ein Fehlschlag beim Aufloesen einer Folge ist kein Urteil ueber den
    /// Eintrag. Die Klassifizierung trennt beides, und nur ein klares Weg
    /// darf vermerken.
    @Test("a 404 for a missing subscription is not a dead entry")
    func aMissingSubscriptionIsNotAGoneEntry() {
        // Der Vermerk gilt nur fuer Katalog-Kennungen. Eine Podcast-Folge
        // gehoert ihrem Feed, und ein 404 sagt hier nur, dass diese App sie
        // gerade nicht aufloesen konnte.
        #expect(!FreeCatalog.isCatalogId("rss:https://example.org/feed.xml:guid-1"),
                "eine Podcast-Folge wuerde als toter Katalog-Eintrag vermerkt")
        // Rot-Probe: an einer echten Katalog-Kennung greift dieselbe Frage.
        #expect(FreeCatalog.isCatalogId(FreeCatalog.jamendoPrefix + "1234"))
    }
}

/// Die Einstellungen einer Sendung erreicht man auch von ihrer Folge
/// aus, und das Blatt nennt die Sendung als erste Zeile statt im Titel.
@MainActor
struct PodcastShowSettingsReachTests {
    @MainActor final class Held { var value = PodcastShowPreferences.default }
    @MainActor final class Notes { var said: [String] = [] }

    static func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("GT-15: eine Wahl im Blatt schreibt ueber die eine Regel, und angesehen schreibt sie nichts")
    func aChoiceWritesThroughTheOneRule() throws {
        let suite = "showsettings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let showId = "rss:https://example.org/feed.xml"
        let held = Held()
        let state = Binding(get: { held.value }, set: { held.value = $0 })

        // What the choice family is told, recorded instead of said: a
        // witness with its own suite must not reach the app's family.
        let notes = Notes()
        let note: @MainActor (Any?, String) -> Void = { value, key in notes.said.append("\(key)=\(value ?? "nil")") }

        PodcastShowPreferences.binding(\.newestFirst, of: state, showId: showId,
                                       mode: .browsed, defaults: defaults, note: note).wrappedValue = false
        #expect(held.value.newestFirst == false, "die Seite sieht die Wahl")
        #expect(defaults.object(forKey: PodcastShowPreferences.sortKey(showId: showId)) == nil,
                "angesehen bleibt der Speicher leer")
        #expect(notes.said.isEmpty, "angesehen reist nichts")

        PodcastShowPreferences.binding(\.newestFirst, of: state, showId: showId,
                                       mode: .subscribed, defaults: defaults, note: note).wrappedValue = false
        PodcastShowPreferences.binding(\.unplayedOnly, of: state, showId: showId,
                                       mode: .subscribed, defaults: defaults, note: note).wrappedValue = true
        #expect(PodcastShowPreferences.load(showId: showId, mode: .subscribed, defaults: defaults)
                    == PodcastShowPreferences(newestFirst: false, unplayedOnly: true),
                "abonniert liest die Seite beide Wahlen wieder")
        // Sort and filter per show travel like the show's other values.
        #expect(notes.said == ["podcastSort.\(showId)=false", "podcastFilter.\(showId)=true"],
                "abonniert reist jede geaenderte Wahl, gesagt: \(notes.said)")

        notes.said = []
        PodcastShowPreferences.binding(\.unplayedOnly, of: state, showId: showId,
                                       mode: .subscribed, defaults: defaults, note: note).wrappedValue = true
        #expect(notes.said.isEmpty, "dieselbe Wahl noch einmal reist nicht")
    }

    @Test("TF-5a: eine Geste schreibt und sagt nur ihre Wahl, ein fremd uebernommener Wert bleibt")
    func aGestureWritesOnlyItsChoice() throws {
        let suite = "showsettings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let showId = "feed:tf5a"
        let sort = PodcastShowPreferences.sortKey(showId: showId)
        let filter = PodcastShowPreferences.filterKey(showId: showId)
        let notes = Notes()
        let note: @MainActor (Any?, String) -> Void = { value, key in notes.said.append("\(key)=\(value ?? "nil")") }

        // The page opened with oldest first and all episodes, and holds that.
        defaults.set(false, forKey: sort)
        defaults.set(false, forKey: filter)
        let held = Held()
        held.value = PodcastShowPreferences.load(showId: showId, mode: .subscribed, defaults: defaults)
        let state = Binding(get: { held.value }, set: { held.value = $0 })
        // Meanwhile the other device chose newest first, and it arrived.
        defaults.set(true, forKey: sort)

        // Here only the filter is tapped, on the page that still holds the old sort.
        PodcastShowPreferences.binding(\.unplayedOnly, of: state, showId: showId,
                                       mode: .subscribed, defaults: defaults, note: note).wrappedValue = true
        #expect(defaults.object(forKey: sort) as? Bool == true, "the arrived sort stays")
        #expect(defaults.object(forKey: filter) as? Bool == true, "the tapped filter is stored")
        #expect(notes.said == ["\(filter)=true"], "only the tapped choice travels, said: \(notes.said)")
    }

    @Test("GT-15 und D7: die Folge oeffnet das Blatt ihrer Sendung, es heisst Einstellungen und nennt die Sendung zuerst", .needsTheSources)
    func theEpisodeOpensTheShowSettings() throws {
        let episode = try Self.source("Sources/Views/Podcasts/PodcastEpisodeDetailView.swift")
        #expect(episode.contains("PodcastShowSettingsButton { showSettings = true }"), "die Folge hat das Zeichen")
        #expect(episode.contains("if let show { PodcastShowSettingsEntry(show: show) }"), "und es oeffnet das Blatt")
        let page = try Self.source("Sources/Views/Podcasts/PodcastShowView.swift")
        #expect(page.contains("PodcastShowSettingsButton { showSettings = true }"), "beide Seiten tragen dasselbe Zeichen")

        let sheet = try Self.source("Sources/Views/Podcasts/PodcastShowSettingsSheet.swift")
        let entry = try #require(functionBody(of: "struct PodcastShowSettingsEntry: View {", in: sheet))
        #expect(entry.contains("mode: .subscribed") && !entry.contains(".browsed"),
                "von der Folge ist die Sendung abonniert, also bleibt die Wahl")
        #expect(sheet.contains(".navigationTitle(\"Settings\")"), "der Titel ist Einstellungen")
        let start = try #require(sheet.range(of: "struct PodcastShowSettingsSheet: View {"))
        let form = try #require(sheet.range(of: "Form {", range: start.upperBound..<sheet.endIndex))
        let name = try #require(sheet.range(of: "Text(show.title)", range: form.upperBound..<sheet.endIndex))
        let speed = try #require(sheet.range(of: "Section(\"Playback Speed\")", range: form.upperBound..<sheet.endIndex))
        #expect(name.upperBound < speed.lowerBound, "die Sendung steht vor allen Feldern")
    }
}

/// Cuts a declaration's body brace-exact. A character window would read past
/// the closing brace and answer for the code after it.
func functionBody(of head: String, in text: String) -> String? {
    guard let start = text.range(of: head) else { return nil }
    var depth = 0
    var index = text.index(before: start.upperBound)
    while index < text.endIndex {
        let character = text[index]
        if character == "{" { depth += 1 }
        if character == "}" {
            depth -= 1
            if depth == 0 { return String(text[start.upperBound..<index]) }
        }
        index = text.index(after: index)
    }
    return nil
}
