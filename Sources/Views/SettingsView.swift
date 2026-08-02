// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Central settings (Variante b): pill tabs at the top — "General" carries
/// everything cross-cutting in the placement-rule order (Sources → Libraries →
/// Sync → Storage → Notifications → Appearance → Statistics → About →
/// Diagnostics), plus ONE pill per enabled media type that has own settings
/// (Audiobooks: playback · Podcasts: recommendations). Placement rule: every
/// setting belongs to exactly one category — source · library · playback ·
/// storage · sync · system/diagnosis; media-specific goes on its media pill,
/// cross-cutting on General (docs/components.md).
struct SettingsView: View {
    @ObservedObject var coordinator: PlayerCoordinator
    /// For reloading after a library switch — the settings are pushed from
    /// the library screen, which owns this view model.
    var libraryViewModel: LibraryViewModel? = nil
    @ObservedObject private var downloadManager = DownloadManager.shared
    let onLogout: () -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Tab: String, CaseIterable, Identifiable {
        // Variante b: General + one pill per media type that (a) is enabled
        // and (b) HAS own settings. Today that is Audiobooks (playback) and
        // Podcasts (recommendations); Music and Radio have no tab-level
        // settings yet (their specifics live on the source pages), so they
        // get no pill — an empty tab would be worse than none.
        case general, audiobooks, podcasts, music
        var id: String { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .general: return "General"
            case .audiobooks: return "Audiobooks"
            case .podcasts: return "Podcasts"
            case .music: return "Music"
            }
        }
    }
    @State private var tab: Tab = .general

    /// Media-type pills only when the type is enabled (no dead pill for a
    /// hidden library) — General is always there.
    private var visibleTabs: [Tab] {
        var tabs: [Tab] = [.general]
        if audiobooksTab { tabs.append(.audiobooks) }
        if podcastsTab { tabs.append(.podcasts) }
        if musicTab { tabs.append(.music) }
        return tabs
    }

    @State private var skipInterval: Double =
        UserDefaults.standard.object(forKey: AppStorageKeys.skipInterval) as? Double ?? 30
    @State private var defaultRate: Double =
        Double(UserDefaults.standard.object(forKey: AppStorageKeys.defaultPlaybackRate) as? Float ?? 1.0)
    @State private var smartRewind: Bool =
        UserDefaults.standard.object(forKey: AppStorageKeys.smartRewind) as? Bool ?? true
    @State private var warnCellular: Bool =
        UserDefaults.standard.object(forKey: AppStorageKeys.warnCellularDownload) as? Bool ?? true
    @State private var autoPlayNext: Bool =
        UserDefaults.standard.bool(forKey: AppStorageKeys.autoPlayNextInSeries)
    @AppStorage(AppStorageKeys.appearance) private var appearance = "system"
    @AppStorage(AppStorageKeys.homeRecommendations) private var homeRecommendations = true
    @AppStorage(AppStorageKeys.podcastICloudSync) private var podcastICloudSync = true
    @AppStorage(AppStorageKeys.podcastNewEpisodeNotifications) private var newEpisodeNotifications = false

    // TF bib-toggles: two-level library toggles. Tab masters (default ON) +
    // per-source (absAudiobooks/rss default ON; the opt-in sources default OFF).
    // Every change routes through `AppSession.reconfigureSources()`.
    @AppStorage(AppStorageKeys.audiobooksTabEnabled) private var audiobooksTab = true
    @AppStorage(AppStorageKeys.podcastsTabEnabled) private var podcastsTab = true
    @AppStorage(AppStorageKeys.musicTabEnabled) private var musicTab = true
    @AppStorage(AppStorageKeys.radioTabEnabled) private var radioTab = true
    @AppStorage(AppStorageKeys.absAudiobooksEnabled) private var absAudiobooksOn = true
    @AppStorage(AppStorageKeys.absPodcastsEnabled) private var absPodcastsOn = false
    @AppStorage(AppStorageKeys.rssEnabled) private var rssOn = true
    @AppStorage(AppStorageKeys.subsonicEnabled) private var subsonicOn = false
    @AppStorage(AppStorageKeys.jellyfinEnabled) private var jellyfinOn = false
    @AppStorage(AppStorageKeys.radioEnabled) private var radioOn = false

    /// Exclusivity note (ABS-podcasts turned gpodder off, or vice versa).
    @State private var podcastServerNote: String?
    @State private var coverCacheBytes: Int64 = 0
    @State private var showDeleteAllDownloads = false

    /// Same speed steps as the full player's speed menu.
    private let availableRates: [Double] = [0.8, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        VStack(spacing: 0) {
            pillTabs
            Form {
                // Variante b: General = everything cross-cutting, in the
                // placement-rule order (sources → libraries → sync → storage →
                // notifications → appearance → stats → about → diagnostics);
                // one pill per media type with its specifics.
                switch tab {
                case .general:
                    sourcesSection
                    librariesSection
                    globalSyncSection
                    storageSection
                    notificationsSection
                    driveModeSection
                    appearanceSection
                    statsSection
                    networkServicesSection
                    aboutSection
                case .audiobooks:
                    playbackSection
                case .podcasts:
                    recommendationsSection
                case .music:
                    musicSection
                }
            }
            .bottomBarClearance()
        }
        .onChange(of: visibleTabs) {
            // The selected media pill can disappear (library toggled off).
            if !visibleTabs.contains(tab) { tab = .general }
        }
        .alert("Podcast source changed", isPresented: Binding(
            get: { podcastServerNote != nil }, set: { if !$0 { podcastServerNote = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(podcastServerNote ?? "") }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    // Locale-independent handle for the UI-test harness.
                    .accessibilityIdentifier("settings-done")
            }
        }
        .task {
            coverCacheBytes = ImageCache.shared.cacheSizeBytes()
        }
        .alert("Delete all downloads?", isPresented: $showDeleteAllDownloads) {
            Button("Delete", role: .destructive) {
                DownloadManager.shared.deleteAllDownloads()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All downloaded audiobooks will be removed from this device. Listening progress is kept.")
        }
    }

    // MARK: - Pill-Tabs

    private var pillTabs: some View {
        HStack(spacing: 8) {
            ForEach(visibleTabs) { t in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { tab = t }
                } label: {
                    Text(t.label)
                        .font(.subheadline.weight(.medium))
                        .padding(.vertical, 7)
                        .padding(.horizontal, 16)
                        .foregroundStyle(tab == t ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .background(
                            tab == t ? AnyShapeStyle(AppTheme.accent) : AnyShapeStyle(.quaternary),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                // Locale-independent handle for the UI-test harness.
                .accessibilityIdentifier("settings-tab-\(t.rawValue)")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Allgemein

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker(selection: $appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            } label: {
                Label("Appearance", systemImage: "circle.lefthalf.filled")
            }
            .pickerStyle(.segmented)
        }
    }

    /// a449534 (6): downloads broken down per media type (each clearable) —
    /// classification via the pure PlayerSourceTargets id rules; the total
    /// line stays. Section follows the button RULEBOOK: facts → toggles →
    /// actions → ONE destructive row (dialog carries the per-type choices).
    private var downloadsByType: [(label: String, ids: [String])] {
        let ids = downloadManager.downloadedItemIds
        return [
            (String(localized: "Audiobooks"), ids.filter { PlayerSourceTargets.isBook($0) }),
            (String(localized: "Podcasts"), ids.filter { PlayerSourceTargets.isPodcast($0) }),
            (String(localized: "Music"), ids.filter { PlayerSourceTargets.isMusic($0) }),
        ]
    }

    @State private var showDeleteDownloadsDialog = false
    private var storageSection: some View {
        Section {
            // Facts
            LabeledContent {
                Text(ByteCountFormatter.string(fromByteCount: downloadManager.totalDownloadsSize, countStyle: .file))
            } label: {
                Label("Downloads", systemImage: "arrow.down.circle")
            }
            ForEach(downloadsByType, id: \.label) { group in
                LabeledContent {
                    Text(ByteCountFormatter.string(
                        fromByteCount: group.ids.reduce(0) { $0 + downloadManager.downloadSize(forItemId: $1) },
                        countStyle: .file))
                } label: {
                    Text(group.label).padding(.leading, 28)
                }
                .font(.subheadline)
            }
            LabeledContent {
                Text(ByteCountFormatter.string(fromByteCount: coverCacheBytes, countStyle: .file))
            } label: {
                Label("Cover Cache", systemImage: "photo.on.rectangle")
            }
            // Toggles
            Toggle(isOn: $warnCellular) {
                Label("Warn When Not on Wi-Fi", systemImage: "wifi")
            }
            .onChange(of: warnCellular) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: AppStorageKeys.warnCellularDownload)
            }
            // Actions
            Button {
                ImageCache.shared.clearCache()
                coverCacheBytes = ImageCache.shared.cacheSizeBytes()
            } label: {
                Label("Clear Cover Cache", systemImage: "trash")
            }
            // Destructive — ONE row, the dialog offers all/per-type.
            Button(role: .destructive) {
                showDeleteDownloadsDialog = true
            } label: {
                Label("Delete Downloads…", systemImage: "trash")
            }
            .disabled(downloadManager.downloadedItemIds.isEmpty)
            .confirmationDialog("Delete downloads?", isPresented: $showDeleteDownloadsDialog,
                                titleVisibility: .visible) {
                Button("Delete All Downloads", role: .destructive) { showDeleteAllDownloads = true }
                ForEach(downloadsByType.filter { !$0.ids.isEmpty }, id: \.label) { group in
                    Button(role: .destructive) {
                        for id in group.ids { downloadManager.deleteDownload(itemId: id) }
                    } label: {
                        Text(verbatim: "\(group.label) (\(group.ids.count))")
                    }
                }
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Deleting downloads never deletes listening progress.")
        }
    }

    /// Variante b, rule category "source": servers/accounts with their on/off
    /// switch and config page — one subsection per media type, every service
    /// equal. The tab level (which media types appear) lives in the separate
    /// Libraries section below; effective activity stays tab ∧ source
    /// (`SourceActivation`), every change routes through
    /// `AppSession.reconfigureSources()`. Keys unchanged.
    @ViewBuilder
    private var sourcesSection: some View {
        Section {
            sourceToggle("Audiobookshelf", isOn: $absAudiobooksOn)
            NavigationLink { ABSSourceView(coordinator: coordinator,
                                           libraryViewModel: libraryViewModel,
                                           onLogout: onLogout) } label: {
                Label("Audiobookshelf server", systemImage: "server.rack")
            }
            .accessibilityIdentifier("settings-abs-source")
            NavigationLink { LocalFilesView(onImported: {
                Task { await libraryViewModel?.refreshAfterLocalChange() }
            }) } label: { Label("Local Files", systemImage: "folder") }
        } header: { Text("Sources — Audiobooks") }

        Section {
            // gpodder ↔ ABS-podcasts are mutually exclusive (one podcast
            // server at a time; RSS below stays free). Enabling ABS turns
            // gpodder off, with a note.
            Toggle(isOn: $absPodcastsOn) { Text("Audiobookshelf podcasts") }
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
        } header: { Text("Sources — Podcasts") }

        Section {
            sourceToggle("Music server (Subsonic)", isOn: $subsonicOn)
            NavigationLink { SubsonicSourceView() } label: {
                Label("Music server", systemImage: "music.note")
            }
            .accessibilityIdentifier("settings-music-source")
            sourceToggle("Jellyfin", isOn: $jellyfinOn)
            NavigationLink { JellyfinSourceView() } label: {
                Label("Jellyfin server", systemImage: "music.note.house")
            }
            .accessibilityIdentifier("settings-jellyfin-source")
        } header: { Text("Sources — Music") } footer: {
            Text("One music server at a time: with both on, Subsonic is used.")
        }

        Section {
            sourceToggle("Internet radio", isOn: $radioOn)
            NavigationLink { RadioSourceView() } label: {
                Label("Radio", systemImage: "dot.radiowaves.left.and.right")
            }
            .accessibilityIdentifier("settings-radio-source")
        } header: { Text("Sources — Radio") } footer: {
            Text("A source off makes zero server calls. Whether a media type appears at all is set under Libraries below.")
        }
    }

    /// Variante b, rule category "library": the tab level of the two-level
    /// gating — which media types appear. Same keys and reconfigure path as
    /// before; the per-source switches stay under Sources above.
    private var librariesSection: some View {
        Section {
            tabMasterToggle("Audiobooks", isOn: $audiobooksTab)
            tabMasterToggle("Podcasts", isOn: $podcastsTab)
            tabMasterToggle("Music", isOn: $musicTab)
            tabMasterToggle("Radio", isOn: $radioTab)
        } header: {
            Text("Libraries")
        } footer: {
            Text("Which media types appear as tabs. A type off hides its tab and stops all its sources' calls — the per-source switches above are kept.")
        }
    }

    /// TF bib-toggles: the tab-master row (bold) — flipping it reconfigures.
    private func tabMasterToggle(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { Text(title).fontWeight(.semibold) }
            .onChange(of: isOn.wrappedValue) { AppSession.shared.reconfigureSources() }
    }

    /// TF bib-toggles: a per-source row — flipping it reconfigures.
    private func sourceToggle(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { Text(title) }
            .onChange(of: isOn.wrappedValue) { AppSession.shared.reconfigureSources() }
    }

    /// Etappe E: the GLOBAL sync section — the history shows all services, so
    /// it lives tab-independent; per-source sync buttons sit on the source
    /// pages (one pattern, no scattered "Sync Now" variants).
    private var globalSyncSection: some View {
        Section {
            NavigationLink {
                SyncHistoryView()
            } label: {
                Label("Sync History", systemImage: "clock.arrow.circlepath")
            }
            Toggle(isOn: $podcastICloudSync) {
                Label("Sync Podcast Progress via iCloud", systemImage: "icloud")
            }
            .onChange(of: podcastICloudSync) { _, on in
                if on { PodcastCloudSync.shared.start() }
            }
        } header: {
            Text("Sync")
        } footer: {
            Text("iCloud keeps podcast progress in sync across your own devices (needs iCloud enabled). Server sync per service lives on its source page.")
        }
    }



    private var aboutSection: some View {
        Section {
            LabeledContent {
                Text(Self.versionString)
            } label: {
                Label("Version", systemImage: "info.circle")
            }
        } header: {
            Text("About")
        } footer: {
            Text("Mär is an unofficial client for Audiobookshelf.")
        }
    }

    // MARK: - Audiobooks

    @AppStorage(AppStorageKeys.freeAudiobooksEnabled) private var freeAudiobooks = true
    private var playbackSection: some View {
        Section {
            Picker(selection: $skipInterval) {
                ForEach([15.0, 30.0, 60.0], id: \.self) { seconds in
                    Text("\(Int(seconds)) seconds").tag(seconds)
                }
            } label: {
                Label("Skip Interval", systemImage: "goforward")
            }
            .onChange(of: skipInterval) { _, newValue in
                if let vm = coordinator.viewModel {
                    vm.setSkipInterval(newValue)   // also updates the lock-screen buttons
                } else {
                    UserDefaults.standard.set(newValue, forKey: AppStorageKeys.skipInterval)
                }
            }

            Picker(selection: $defaultRate) {
                ForEach(availableRates, id: \.self) { rate in
                    Text("\(rate.formatted(.number.precision(.fractionLength(0...2))))×").tag(rate)
                }
            } label: {
                Label("Default Speed", systemImage: "speedometer")
            }
            .onChange(of: defaultRate) { _, newValue in
                UserDefaults.standard.set(Float(newValue), forKey: AppStorageKeys.defaultPlaybackRate)
            }

            Toggle(isOn: $smartRewind) {
                Label("Smart Rewind", systemImage: "backward.circle")
            }
            .onChange(of: smartRewind) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: AppStorageKeys.smartRewind)
            }

            Toggle(isOn: $autoPlayNext) {
                Label("Auto-Play Next in Series", systemImage: "play.circle")
            }
            .onChange(of: autoPlayNext) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: AppStorageKeys.autoPlayNextInSeries)
            }

            // 7edb21b: FEATURE level for the whole free-audiobooks area
            // (tab entry + Discover mix) — the classical-toggle pattern;
            // the LibriVox service opt-out on the network-services page
            // stays superior (service off wins).
            Toggle("Show free audiobooks", isOn: $freeAudiobooks)
                .accessibilityIdentifier("books-free-audiobooks-toggle")
        } header: {
            Text("Playback")
        } footer: {
            Text("New books start at the default speed. Smart Rewind resumes a little earlier after a longer pause. When a series book ends, the next unfinished one starts automatically. Free audiobooks adds a public-domain LibriVox area, separate from your library.")
        }
    }

    // MARK: - Podcasts

    /// Variante b: recommendations live on the Podcasts pill (the Discover
    /// engine is podcast-driven). Still ONE opt-out for both Home sections
    /// (Rediscover + Discover) — key unchanged.
    /// a449534 (1): the provider-WIDE music feature toggles — moved off the
    /// Subsonic SOURCE page (feature ≠ access; they apply to Jellyfin too).
    /// Same AppStorage keys, one truth.
    @AppStorage(AppStorageKeys.musicLyricsOnlineLookup) private var lyricsOnline = true
    @AppStorage(AppStorageKeys.musicHighResCovers) private var highResCovers = true
    @AppStorage(AppStorageKeys.musicArtistImagesOnline) private var artistImagesOnline = true
    @AppStorage(AppStorageKeys.freeClassicalEnabled) private var freeClassical = true
    private var musicSection: some View {
        Section {
            Toggle("Look up lyrics online", isOn: $lyricsOnline)
                .accessibilityIdentifier("music-lyrics-toggle")
            Toggle("Load artist images from the web", isOn: $artistImagesOnline)
            Toggle("High-res covers (Cover Art Archive)", isOn: $highResCovers)
            // f18ec34: FEATURE level — the whole Free-Classical area (browse
            // entry + Home teaser); the archive.org service opt-out on the
            // network-services page stays superior (service off wins).
            Toggle("Show Free Classical", isOn: $freeClassical)
                .accessibilityIdentifier("music-free-classical-toggle")
        } header: {
            Text("Metadata")
        } footer: {
            Text("Lyrics come from your server first; LRCLIB is used as an open fallback. High-res covers load from the Cover Art Archive for albums with a MusicBrainz ID. Both are open services without accounts.")
        }
    }

    /// a449534 (4): ONE page listing every external service with its purpose
    /// and the REAL opt-out switch (same keys as the feature homes — a second
    /// access point, never a second truth).
    private var networkServicesSection: some View {
        Section {
            NavigationLink {
                NetworkServicesView()
            } label: {
                Label("Network Services & Privacy", systemImage: "network.badge.shield.half.filled")
            }
            .accessibilityIdentifier("settings-network-services")
        }
    }

    private var recommendationsSection: some View {
        Section {
            Toggle(isOn: $homeRecommendations) {
                Label("Recommendations", systemImage: "sparkles")
            }
            // f79c40c: the MULTI-select suggestion language — explicit choice
            // beats the locale guess; catalog/recommendation requests only.
            NavigationLink {
                SuggestionLanguagesView()
            } label: {
                Label("Suggestion Languages", systemImage: "globe")
            }
            .accessibilityIdentifier("settings-suggestion-languages")
        } header: {
            Text("Home")
        } footer: {
            Text("Shows the Rediscover and Discover sections on Home. Suggestions are computed on this device; no listening profile leaves it.")
        }
    }



    /// Drive mode: choose the ONE car audio output (from the currently
    /// connected routes); 9357955: auto-start is an explicit opt-in toggle,
    /// default OFF — without it the mode only starts from the player button.
    @State private var carRouteName = UserDefaults.standard.string(forKey: AppStorageKeys.driveModeCarRouteName) ?? ""
    @AppStorage(AppStorageKeys.driveModeAutoStart) private var driveModeAutoStart = false
    private var driveModeSection: some View {
        Section {
            if !carRouteName.isEmpty {
                LabeledContent {
                    Text(carRouteName)
                } label: {
                    Label("Car audio", systemImage: "car.fill")
                }
                Toggle(isOn: $driveModeAutoStart) {
                    Text("Start automatically when \(carRouteName) connects")
                }
                // Rulebook: destructive-class action, red, LAST row.
                Button(role: .destructive) {
                    UserDefaults.standard.removeObject(forKey: AppStorageKeys.driveModeCarRouteUID)
                    UserDefaults.standard.removeObject(forKey: AppStorageKeys.driveModeCarRouteName)
                    carRouteName = ""
                } label: {
                    Text("Forget car audio")
                }
            } else {
                let outputs = DriveModeController.currentOutputs()
                if outputs.isEmpty {
                    Text("Connect your car audio, then choose it here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(outputs, id: \.uid) { output in
                        Button {
                            UserDefaults.standard.set(output.uid, forKey: AppStorageKeys.driveModeCarRouteUID)
                            UserDefaults.standard.set(output.name, forKey: AppStorageKeys.driveModeCarRouteName)
                            carRouteName = output.name
                        } label: {
                            Label(output.name, systemImage: "speaker.wave.2")
                        }
                    }
                }
            }
        } header: {
            Text("Drive Mode")
        } footer: {
            // Honest limit (9357955): iOS does not launch apps on a Bluetooth
            // connect — auto-start works while the app runs / comes to the
            // foreground. No false promises.
            Text("With the toggle on, drive mode starts when the chosen audio output connects while the app is running or returns to the foreground — iOS does not launch apps on a Bluetooth connection. It can always be started from the player. It is a big-button layout, not a safety feature.")
        }
    }

    /// E7: statistics moved from the Audiobooks pill to General — labelled with
    /// their source (today only Audiobookshelf listening data).
    private var statsSection: some View {
        Section {
            NavigationLink {
                StatsView(libraryViewModel: libraryViewModel)
            } label: {
                Label("Statistics", systemImage: "chart.bar.fill")
            }
        } footer: {
            Text("Listening statistics come from Audiobookshelf.")
        }
    }

    /// E6: tab-independent Notifications section (moved off the removed Podcasts
    /// pill) — the podcast new-episode toggle lives here, future notification
    /// settings join it.
    private var notificationsSection: some View {
        Section {
            Toggle(isOn: $newEpisodeNotifications) {
                Label("Notify About New Episodes", systemImage: "bell")
            }
            .onChange(of: newEpisodeNotifications) { _, on in
                guard on else { return }
                Task {
                    let granted = await PodcastRefreshService.requestAuthorization()
                    if !granted { newEpisodeNotifications = false }
                    else { PodcastRefreshService.schedule() }
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Checks your podcast subscriptions in the background and notifies you when new episodes are published. Requires notification permission.")
        }
    }


    private static var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
        // Build stamp: the short git SHA of the BUILT state (stamped into the
        // Info.plist by the "Stamp git SHA" build phase) — device tests are now
        // unambiguously attributable to a commit (a stale incremental build
        // shows its old SHA instead of silently masquerading as the fix).
        if let sha = Bundle.main.object(forInfoDictionaryKey: "GitSHA") as? String, !sha.isEmpty {
            return "\(version) (\(build)) · \(sha)"
        }
        return "\(version) (\(build))"
    }
}
