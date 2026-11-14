// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
import SwiftUI
@testable import Maer

/// One show page, two states. The fences pin the boundary:
/// viewing writes nothing, playing writes exactly one listening state, and the
/// locks are construction instead of visual inspection.
struct PodcastShowModeTests {

    // MARK: - Viewing writes nothing

    /// The core of the requirement: viewing an unsubscribed show, drawing its
    /// list and sorting it leaves the store byte-identical.
    /// The fence sits at the ONE write place, not at the view, so that
    /// a call site added later cannot bypass it.
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

        // Red probe on the instrument: the same call in the subscribed state
        // does write. A fence that never sees anything proves nothing.
        prefs.save(showId: showId, mode: .subscribed, defaults: defaults)
        #expect(defaults.object(forKey: PodcastShowPreferences.sortKey(showId: showId)) as? Bool == false)
        #expect(defaults.object(forKey: PodcastShowPreferences.filterKey(showId: showId)) as? Bool == true)
    }

    /// A viewed show starts at the default, even if old keys still lie under
    /// its identifier. Otherwise an earlier subscription would have carried
    /// an invisible filter into the new view.
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

    // MARK: - The locks are construction

    /// What the subscription really distinguishes is there as a value. The view
    /// asks it, instead of writing `if subscribed` in four places.
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

    // MARK: - There is only one show page left

    /// The second show page is gone, and the route leads both states
    /// to the same view. Without this fence the preview would return as a
    /// special case, and the two surfaces would drift apart again.
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

    /// The subscription state must not depend on the LOADING STATE of the stores. The
    /// stores fill concurrently; a page opened during a
    /// cold start finds them empty. Whoever passes the show in as a VALUE
    /// has it from a store, and the search ends there.
    /// Otherwise the page would offer to subscribe to an already subscribed show,
    /// and that is exactly the acceptance mark.
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

    /// The download button is ABSENT in the viewed state, not
    /// disabled. The page resolves the capability once and passes it
    /// down, like the origin capsule.
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

    // MARK: - Marking as heard by hand

    /// Marking is a statement about one's own listening and so belongs in
    /// the same family as a listening state, even without a subscription. It writes the
    /// end position through the third write place, and the rule did not
    /// cover that one: without it the position outlives its resolution, and the tile
    /// carries no name.
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

        // Red probe: the unheard note says the opposite and therefore writes
        // nothing down. Without it, a write place that writes down EVERY
        // identifier would report green just the same.
        ListeningStore.store(untouched,
                             entry: ProgressMark.entry(position: 0, duration: 0, nowMs: 1_000),
                             in: defaults)
        #expect(BrowsedEpisodes.shared.listened(guid: untouched, defaults: defaults) == nil,
                "der Ungehoert-Vermerk schreibt die Folge nieder")
    }

    // MARK: - A 404 due to a missing subscription notes nothing as gone

    /// A failure when resolving an episode is no verdict on the
    /// entry. The classification separates the two, and only a clear gone
    /// may note it.
    @Test("a 404 for a missing subscription is not a dead entry")
    func aMissingSubscriptionIsNotAGoneEntry() {
        // The note applies only to catalog identifiers. A podcast episode
        // belongs to its feed, and a 404 here says only that this app could not
        // resolve it just now.
        #expect(!FreeCatalog.isCatalogId("rss:https://example.org/feed.xml:guid-1"),
                "eine Podcast-Folge wuerde als toter Katalog-Eintrag vermerkt")
        // Red probe: on a real catalog identifier the same question applies.
        #expect(FreeCatalog.isCatalogId(FreeCatalog.jamendoPrefix + "1234"))
    }
}

/// The settings of a show can also be reached from its episode,
/// and the sheet names the show as the first line instead of in the title.
@MainActor
struct PodcastShowSettingsReachTests {
    @MainActor final class Held { var value = PodcastShowPreferences.default }
    @MainActor final class Notes { var said: [String] = [] }

    static func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("a choice in the sheet writes through the one rule, and when viewed it writes nothing")
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

    @Test("a gesture writes and says only its choice, a value adopted from elsewhere stays")
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

    @Test("GT-15 and D7: the episode opens the sheet of its show, it is called Settings and names the show first", .needsTheSources)
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
