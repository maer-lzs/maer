// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// THE map of areas. Rendered in exactly two places: on the first screen
/// (empty state) and as the sources overview in the settings (filled state).
/// One component, two hosts: that is also what makes the way BACK to the first
/// screen exist at all, which it did not before.
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
                    VStack(alignment: .leading, spacing: 3) {
                        Label(Self.title(area), systemImage: area.symbol)
                        Self.stateLine(area, facts: facts)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("source-map-\(area.rawValue)")
            }
        } header: {
            Text("Areas")
        } footer: {
            Text("Four of the five areas need no account at all. Servers can be attached here at any time — nothing has to be set up before listening.")
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

    /// The one line per area: what it needs, or what answers for it. G8 in
    /// reverse. An area without a server says what it would need.
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
            case .podcasts: return Text("No account needed — feeds right away")
            case .radio: return Text("No account needed — stations worldwide")
            default: return Text("No account needed — LibriVox, radio plays, netlabels, old records")
            }
        }
    }
}

extension SourceMapFacts {
    /// The stored facts, read in ONE place. Hosts only. Never credentials.
    @MainActor
    static var current: SourceMapFacts {
        var facts = SourceMapFacts()
        facts.absConnected = AppSession.shared.authViewModel.isLoggedIn
        facts.absServer = AppSession.shared.apiClient.baseURL.absoluteString
        facts.subsonicConfigured = AppStorageKeys.subsonicConfigured
        facts.subsonicServer = AppStorageKeys.subsonicServerURLValue
        facts.jellyfinConfigured = !AppStorageKeys.jellyfinServerURLValue.isEmpty
            && !AppStorageKeys.jellyfinUsernameValue.isEmpty
        facts.jellyfinServer = AppStorageKeys.jellyfinServerURLValue
        facts.gpodderConfigured = AppStorageKeys.gpodderConfigured
        facts.gpodderServer = AppStorageKeys.gpodderServerURLValue
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
    @AppStorage(AppStorageKeys.radioEnabled) private var radioOn = false
    @AppStorage(AppStorageKeys.freeCatalogsMasterEnabled) private var freeCatalogsMaster = true
    @AppStorage(AppStorageKeys.freeAudiobooksEnabled) private var freeAudiobooks = true
    @AppStorage(AppStorageKeys.netlabelsRowEnabled) private var netlabelsRow = true
    @AppStorage(AppStorageKeys.shellacRowsEnabled) private var shellacRows = true
    @AppStorage(AppStorageKeys.jamendoRowEnabled) private var jamendoRow = true

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
                        podcastServerNote = String(localized: "gpodder sync was turned off — only one podcast server at a time.")
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
            Text("Stations come from the community catalog — no account. A source off makes zero calls.")
        }
    }

    @ViewBuilder
    private var freeCatalogsSection: some View {
        Section {
            AppSwitch("Show free audiobooks", isOn: $freeAudiobooks)
                .accessibilityIdentifier("books-free-audiobooks-toggle")
                // Master off greys the area toggles. Visibly subordinate,
                // no silent double state.
                .disabled(!freeCatalogsMaster)
            // The areas list has to be COMPLETE. Free music was the one
            // area steering a visible surface without a switch here (only the
            // SERVICE switch under network services, which answers a
            // different question: privacy, not presence). `FreeCatalogArea`
            // is the one enumeration now, and a fence holds this list against
            // it, so the next catalog cannot be forgotten again.
            AppSwitch("Show Free Music", isOn: $jamendoRow)
                .accessibilityIdentifier("music-jamendo-toggle")
                .disabled(!freeCatalogsMaster)
            AppSwitch("Show Netlabels", isOn: $netlabelsRow)
                .accessibilityIdentifier("music-netlabels-toggle")
                .disabled(!freeCatalogsMaster)
            AppSwitch("Show Old Records", isOn: $shellacRows)
                .accessibilityIdentifier("music-shellac-toggle")
                .disabled(!freeCatalogsMaster)
        } header: {
            Text("Areas")
        } footer: {
            if freeCatalogsMaster {
                Text("Public-domain readings, radio plays, free labels and historic recordings — clearly separated from your own library. Sources: \(NetworkServiceNames.freeCatalogs).")
            } else {
                Text("Free catalogs are switched off entirely under General — these switches take effect again once they are back on.")
            }
        }

        Section {
            NavigationLink { NetworkServicesView() } label: {
                Label("Services behind them", systemImage: "network")
            }
            .accessibilityIdentifier("free-catalogs-services")
        } footer: {
            Text("Which servers are contacted for these areas — and how to switch a single one off — is on the network services page.")
        }
    }
}
