import SwiftUI

/// Central settings (Etappe E layout), split into pill tabs at the top:
/// "General" carries the tab-INDEPENDENT sections — Sources (all services
/// equal, one row per source) and Sync (history of all services + iCloud) —
/// plus appearance/storage/about; "Audiobooks" and "Podcasts" keep only their
/// playback/UI specifics.
struct SettingsView: View {
    @ObservedObject var coordinator: PlayerCoordinator
    /// For reloading after a library switch — the settings are pushed from
    /// the library screen, which owns this view model.
    var libraryViewModel: LibraryViewModel? = nil
    @ObservedObject private var downloadManager = DownloadManager.shared
    let onLogout: () -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Tab: String, CaseIterable, Identifiable {
        // E6: the Podcasts pill is gone — its only setting (new-episode
        // notifications) moved to the tab-independent Notifications section
        // under General. Audiobooks keeps its playback specifics.
        case general, audiobooks
        var id: String { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .general: return "General"
            case .audiobooks: return "Audiobooks"
            }
        }
    }
    @State private var tab: Tab = .general

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

    @State private var coverCacheBytes: Int64 = 0
    @State private var showDeleteAllDownloads = false

    /// Same speed steps as the full player's speed menu.
    private let availableRates: [Double] = [0.8, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        VStack(spacing: 0) {
            pillTabs
            Form {
                // Etappe E layout: SOURCES and SYNC are tab-independent
                // (all services equal, the history shows them all); the media
                // pills keep only their playback/UI specifics.
                switch tab {
                case .general:
                    sourcesSection
                    globalSyncSection
                    notificationsSection
                    appearanceSection
                    recommendationsSection
                    statsSection
                    storageSection
                    aboutSection
                case .audiobooks:
                    playbackSection
                }
            }
            .bottomBarClearance()
        }
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
            ForEach(Tab.allCases) { t in
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

    private var storageSection: some View {
        Section {
            Toggle(isOn: $warnCellular) {
                Label("Warn When Not on Wi-Fi", systemImage: "wifi")
            }
            .onChange(of: warnCellular) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: AppStorageKeys.warnCellularDownload)
            }

            LabeledContent {
                Text(ByteCountFormatter.string(fromByteCount: downloadManager.totalDownloadsSize, countStyle: .file))
            } label: {
                Label("Downloads", systemImage: "arrow.down.circle")
            }
            Button(role: .destructive) {
                showDeleteAllDownloads = true
            } label: {
                Label("Delete All Downloads", systemImage: "trash")
            }
            .disabled(downloadManager.downloadedItemIds.isEmpty)

            LabeledContent {
                Text(ByteCountFormatter.string(fromByteCount: coverCacheBytes, countStyle: .file))
            } label: {
                Label("Cover Cache", systemImage: "photo.on.rectangle")
            }
            Button {
                ImageCache.shared.clearCache()
                coverCacheBytes = ImageCache.shared.cacheSizeBytes()
            } label: {
                Label("Clear Cover Cache", systemImage: "trash")
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Deleting downloads never deletes listening progress.")
        }
    }

    /// Etappe E: ONE tab-independent Sources section — every service equal,
    /// one row per source, each source page follows the same pattern
    /// (access / toggle / its own sync button).
    private var sourcesSection: some View {
        Section {
            NavigationLink {
                ABSSourceView(coordinator: coordinator,
                              libraryViewModel: libraryViewModel,
                              onLogout: onLogout)
            } label: {
                Label("Audiobookshelf", systemImage: "server.rack")
            }
            .accessibilityIdentifier("settings-abs-source")
            NavigationLink {
                PodcastSourceView()
            } label: {
                Label("Podcasts", systemImage: "mic")
            }
            .accessibilityIdentifier("settings-podcast-source")
            NavigationLink {
                SubsonicSourceView()
            } label: {
                Label("Music Server", systemImage: "music.note")
            }
            // Locale-independent handle for the UI-test harness.
            .accessibilityIdentifier("settings-music-source")
            NavigationLink {
                RadioSourceView()
            } label: {
                Label("Radio", systemImage: "dot.radiowaves.left.and.right")
            }
            .accessibilityIdentifier("settings-radio-source")
            NavigationLink {
                LocalFilesView(onImported: {
                    Task { await libraryViewModel?.refreshAfterLocalChange() }
                })
            } label: {
                Label("Local Files", systemImage: "folder")
            }
        } header: {
            Text("Sources")
        } footer: {
            Text("Every source is optional and can be added or removed here at any time.")
        }
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
        } footer: {
            Text("Mär is an unofficial client for Audiobookshelf.")
        }
    }

    // MARK: - Audiobooks

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
        } header: {
            Text("Playback")
        } footer: {
            Text("New books start at the default speed. Smart Rewind resumes a little earlier after a longer pause. When a series book ends, the next unfinished one starts automatically.")
        }
    }

    /// Teil 5: ONE opt-out for both Home recommendation sections (Rediscover +
    /// Discover) — same convention as the other metadata toggles (default on).
    private var recommendationsSection: some View {
        Section {
            Toggle(isOn: $homeRecommendations) {
                Label("Recommendations", systemImage: "sparkles")
            }
        } header: {
            Text("Home")
        } footer: {
            Text("Shows the Rediscover and Discover sections on Home. Suggestions are computed on this device; no listening profile leaves it.")
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
        return "\(version) (\(build))"
    }
}
