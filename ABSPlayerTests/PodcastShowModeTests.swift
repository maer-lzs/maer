// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import ABSPlayer

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
    @Test("the state carries the abilities, and the browsed state has none of them")
    func capabilitiesFollowTheState() {
        let subscribed = PodcastShowCapabilities.of(.subscribed)
        let browsed = PodcastShowCapabilities.of(.browsed)

        #expect(subscribed.managesSubscription && !browsed.managesSubscription)
        #expect(subscribed.showsSettingsSheet && !browsed.showsSettingsSheet)
        #expect(subscribed.remembersPreferences && !browsed.remembersPreferences)
        #expect(subscribed.downloads && !browsed.downloads)
        #expect(subscribed.fetchesMoreEpisodes && !browsed.fetchesMoreEpisodes)
        #expect(subscribed.marksAllEpisodes && !browsed.marksAllEpisodes)
    }

    // MARK: - Es gibt nur noch eine Sendungsseite

    /// Die zweite Sendungsseite ist weg, und die Route fuehrt beide Zustaende
    /// auf dieselbe Ansicht. Ohne diesen Zaun kaeme die Vorschau als
    /// Sonderfall zurueck, und die beiden Flaechen drifteten wieder.
    @Test("there is one show page, and the route leads both states to it")
    func oneShowPageOnly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        var names: [String] = []
        if let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "swift" {
                names.append(url.lastPathComponent)
            }
        }
        guard !names.isEmpty else { return }
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
    @Test("a show handed in by value ends the lookup, so a cold open stays subscribed")
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
    @Test("the row asks for the download ability instead of deciding itself")
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
