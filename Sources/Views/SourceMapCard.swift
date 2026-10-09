// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// THE map of areas. Rendered in three places: on the first screen (empty
/// state), after the first setup (next steps) and as the sources overview in
/// the settings (filled state). One component, three hosts: that is also what
/// makes the way BACK to the first screen exist at all, which it did not
/// before. Below the areas it names Mär Sync, which is not an area but the
/// way this device's state reaches the others.
///
/// The host supplies only where a row leads, because that genuinely differs:
/// during the first run there is no session yet, so "Audiobooks" leads to the
/// login form; in the settings it leads to the full source page.
struct SourceMapCard: View {
    let facts: SourceMapFacts
    let destination: (SourceMapArea) -> AnyView

    var body: some View {
        Section {
            ForEach(SourceMapArea.allCases) { area in
                NavigationLink {
                    destination(area)
                } label: {
                    HStack {
                        SourceMapRowLabel(title: Self.title(area), symbol: area.symbol,
                                          line: Self.stateLine(area, facts: facts))
                        Spacer()
                        // The tick is measured, not remembered: a server
                        // of the user's own answers for the area.
                        if Self.isConnected(area, facts: facts) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(Text("Connected"))
                        }
                    }
                }
                .accessibilityIdentifier("source-map-\(area.rawValue)")
            }
        } header: {
            Text("Areas")
        } footer: {
            Text("Three of the five areas need no account at all. Servers can be attached here at any time; nothing has to be set up before listening.")
        }
        // Not a media area: the way this device's state reaches the others.
        // In the component, so all three hosts show it the same way.
        Section {
            NavigationLink {
                MaerSyncSettingsView()
            } label: {
                let line = SourceMapSyncLine.of(facts.syncStanding, host: facts.syncHost)
                HStack {
                    SourceMapRowLabel(title: "Mär Sync", symbol: "server.rack", line: Text(line.text))
                    Spacer()
                    if line.connected {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("Connected"))
                    }
                }
            }
            .accessibilityIdentifier("source-map-sync")
        } header: {
            Text("Between your devices")
        } footer: {
            Text("Not a media area: keeps progress, playlists and settings the same on your devices. Without Mär Sync, iCloud does it.")
        }
    }

    static func title(_ area: SourceMapArea) -> LocalizedStringKey {
        switch area {
        case .audiobooks: return "Audiobooks"
        case .music: return "Music"
        case .podcasts: return "Podcasts"
        case .radio: return "Radio"
        case .freeCatalogs: return "Free Catalogs"
        }
    }

    static func isConnected(_ area: SourceMapArea, facts: SourceMapFacts) -> Bool {
        switch facts.state(of: area) {
        case .connected, .readySynced, .ready: return true
        case .needsServer: return false
        }
    }

    /// The one line per area: what it needs, or what answers for it. An area
    /// without a server says what it would need.
    static func stateLine(_ area: SourceMapArea, facts: SourceMapFacts) -> Text {
        switch facts.state(of: area) {
        case .connected(let host):
            return Text("Connected to \(host)")
        case .readySynced(let host):
            return Text("No account needed · synced with \(host)")
        case .needsServer:
            return area == .audiobooks
                ? Text("Needs an Audiobookshelf server")
                : Text("Needs a Subsonic, Navidrome or Jellyfin server")
        case .ready:
            switch area {
            case .podcasts: return Text("No account needed, feeds right away")
            case .radio: return Text("No account needed, stations worldwide")
            default: return Text("No account needed: LibriVox, radio plays, netlabels, old records")
            }
        }
    }
}

/// One row of the map: its symbol, its title and the line under it. At an
/// accessibility size the line stands in the label's title, so it keeps the
/// title's edge, where the row's separator starts, instead of running under
/// the symbol; at the other sizes the line stays under the whole label.
struct SourceMapRowLabel: View {
    let title: LocalizedStringKey
    let symbol: String
    let line: Text
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Whether the line belongs to the label's title at this size.
    nonisolated static func lineInTitle(_ size: DynamicTypeSize) -> Bool {
        size.isAccessibilitySize
    }

    var body: some View {
        if Self.lineInTitle(typeSize) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                    styledLine
                }
            } icon: {
                Image(systemName: symbol)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: symbol)
                styledLine
            }
        }
    }

    private var styledLine: some View {
        line.font(.caption).foregroundStyle(.secondary)
    }
}

extension SourceMapFacts {
    /// The stored facts, read in ONE place. Hosts only. Never credentials.
    @MainActor
    static var current: SourceMapFacts {
        var facts = SourceMapFacts()
        let auth = AppSession.shared.authViewModel
        facts.absConnected = auth.isLoggedIn
        facts.absServer = auth.serverAddress
        facts.subsonicConfigured = AppStorageKeys.subsonicConfigured
        facts.subsonicServer = AppStorageKeys.subsonicServerURLValue
        facts.jellyfinConfigured = !AppStorageKeys.jellyfinServerURLValue.isEmpty
            && !AppStorageKeys.jellyfinUsernameValue.isEmpty
        facts.jellyfinServer = AppStorageKeys.jellyfinServerURLValue
        facts.gpodderConfigured = AppStorageKeys.gpodderConfigured
        facts.gpodderEnabled = AppStorageKeys.gpodderEnabledValue
        facts.gpodderServer = AppStorageKeys.gpodderServerURLValue
        let sync = MaerSyncStandingReader.current()
        facts.syncStanding = sync.standing
        facts.syncHost = sync.host
        return facts
    }
}

/// The page behind one map row: the area's sources with their switches and
/// their config pages. This is where the four former "Sources — X" sections
/// went, and where the homeless catalog switches finally have an address.
///
/// The placement rule. And there IS one, it was only hidden by the key
/// names (`librivoxRowsEnabled` sounds like a row, `freeClassicalEnabled`
/// sounds like a service; both read the other way round):
///
///  * **one entry per external SERVICE** on the network-services page. Whom
///    does the app contact (LibriVox, Internet Archive, Jamendo, logo chain).
///  * **one entry per AREA** here. What content appears. Free Classical,
///    Netlabels and Old Records are three AREAS on the one archive.org
///    service, which is why they are not on that page and never were an
///    inconsistency.
///
/// What was genuinely homeless are the four area switches: they sat in two
/// different media pills although all four belong to the same area of the
/// map. They are here now; the master stays on General, where it is prominent.
struct SourceAreaPage: View {
    let area: SourceMapArea
    /// Where "Audiobookshelf" leads: during the first run the login form,
    /// afterwards the full source page (which needs a session to exist).
    var absDestination: () -> AnyView

    @AppStorage(AppStorageKeys.absAudiobooksEnabled) private var absAudiobooksOn = true
    @AppStorage(AppStorageKeys.absPodcastsEnabled) private var absPodcastsOn = false
    @AppStorage(AppStorageKeys.rssEnabled) private var rssOn = true
    @AppStorage(AppStorageKeys.subsonicEnabled) private var subsonicOn = false
    @AppStorage(AppStorageKeys.jellyfinEnabled) private var jellyfinOn = false
    @AppStorage(AppStorageKeys.radioEnabled) private var radioOn = true

    @State private var podcastServerNote: String?

    var body: some View {
        Form {
            switch area {
            case .audiobooks: audiobooksSection
            case .music: musicSection
            case .podcasts: podcastsSection
            case .radio: radioSection
            case .freeCatalogs: freeCatalogsSection
            }
            ServerGuidesSection(area: area)
        }
        .navigationTitle(SourceMapCard.title(area))
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
        // The exclusivity note travelled with its switch. It must stay as
        // loud as it was (one podcast server at a time is a real change).
        .alert("Podcast source changed", isPresented: Binding(
            get: { podcastServerNote != nil }, set: { if !$0 { podcastServerNote = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(podcastServerNote ?? "") }
    }

    /// Every switch routes through the same reconfigure path as before.
    private func sourceToggle(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        AppSwitch(title, isOn: isOn)
            .onChange(of: isOn.wrappedValue) { AppSession.shared.reconfigureSources() }
    }

    @ViewBuilder
    private var audiobooksSection: some View {
        Section {
            sourceToggle("Audiobookshelf", isOn: $absAudiobooksOn)
            NavigationLink { absDestination() } label: {
                Label("Audiobookshelf server", systemImage: "server.rack")
            }
            .accessibilityIdentifier("settings-abs-source")
            NavigationLink { LocalFilesView() } label: {
                Label("Local Files", systemImage: "folder")
            }
        } footer: {
            Text("Your own audiobook server. Files on this device work without any server. Connecting to a server on your home network may ask for local-network permission.")
        }
    }

    @ViewBuilder
    private var musicSection: some View {
        Section {
            sourceToggle("Music server (Subsonic)", isOn: $subsonicOn)
            NavigationLink { SubsonicSourceView() } label: {
                Label("Music Server", systemImage: "music.note")
            }
            .accessibilityIdentifier("settings-music-source")
            sourceToggle("Jellyfin", isOn: $jellyfinOn)
            NavigationLink { JellyfinSourceView() } label: {
                Label("Jellyfin Server", systemImage: "music.note.house")
            }
            .accessibilityIdentifier("settings-jellyfin-source")
        } footer: {
            Text("One music server at a time: with both on, Subsonic is used.")
        }
    }

    @ViewBuilder
    private var podcastsSection: some View {
        Section {
            // gpodder ↔ ABS podcasts stay mutually exclusive (one podcast
            // server at a time; RSS below stays free either way).
            AppSwitch(isOn: $absPodcastsOn) { Text("Audiobookshelf podcasts") }
                .onChange(of: absPodcastsOn) {
                    if AppStorageKeys.setABSPodcastsEnabled(absPodcastsOn) {
                        podcastServerNote = String(localized: "gpodder sync was turned off: only one podcast server at a time.")
                    }
                    AppSession.shared.reconfigureSources()
                }
            sourceToggle("RSS feeds", isOn: $rssOn)
                .accessibilityIdentifier("settings-source-rss")
            NavigationLink { PodcastSourceView() } label: {
                Label("Podcast sources", systemImage: "mic")
            }
            .accessibilityIdentifier("settings-podcast-source")
        } footer: {
            Text("Feeds work without any account. A server is only needed to keep subscriptions in sync across devices.")
        }
    }

    @ViewBuilder
    private var radioSection: some View {
        Section {
            sourceToggle("Internet radio", isOn: $radioOn)
            NavigationLink { RadioSourceView() } label: {
                Label("Radio", systemImage: "dot.radiowaves.left.and.right")
            }
            .accessibilityIdentifier("settings-radio-source")
        } footer: {
            Text("Stations come from the community catalog, no account. A source off makes zero calls.")
        }
    }

    @ViewBuilder
    private var freeCatalogsSection: some View {
        // The area toggles used to live HERE and wrote row keys past the
        // cleanup rule (a hidden row left its sources allowed-but-unasked).
        // Both questions now have their one page each; this card links.
        Section {
            NavigationLink { RowsSettingsView() } label: {
                Label("Rows", systemImage: "rectangle.grid.1x2")
            }
            .accessibilityIdentifier("free-catalogs-rows")
            NavigationLink { SourcesSettingsView() } label: {
                Label("Services behind them", systemImage: "network")
            }
            .accessibilityIdentifier("free-catalogs-services")
        } footer: {
            Text("Public-domain readings, radio plays, free labels and historic recordings, clearly separated from your own library. Which rows appear and which services may be asked each have their own page. Sources: \(NetworkServiceNames.freeCatalogs).")
        }
    }
}
