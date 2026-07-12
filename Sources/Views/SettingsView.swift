import SwiftUI

/// Zentrale Einstellungen, oben in Pill-Tabs aufgeteilt: „Allgemein" (Darstellung,
/// Speicher, Sync, Server, App-Info) und je Medientyp „Hörbücher" (Wiedergabe,
/// Bibliothek, Statistik, lokale Dateien) und „Podcasts" (Quellen, iCloud-Sync).
struct SettingsView: View {
    @ObservedObject var coordinator: PlayerCoordinator
    /// For reloading after a library switch — the settings are pushed from
    /// the library screen, which owns this view model.
    var libraryViewModel: LibraryViewModel? = nil
    @ObservedObject private var downloadManager = DownloadManager.shared
    let onLogout: () -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Tab: String, CaseIterable, Identifiable {
        case general, audiobooks, podcasts
        var id: String { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .general: return "General"
            case .audiobooks: return "Audiobooks"
            case .podcasts: return "Podcasts"
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
    @AppStorage(AppStorageKeys.podcastICloudSync) private var podcastICloudSync = true
    @AppStorage(AppStorageKeys.podcastNewEpisodeNotifications) private var newEpisodeNotifications = false

    @State private var availableLibraries: [ABSLibrary] = []
    @AppStorage(AppStorageKeys.selectedLibraryId) private var selectedLibraryId = ""
    @State private var coverCacheBytes: Int64 = 0
    @State private var pendingSyncCount = 0
    @State private var isSyncing = false
    @State private var showDeleteAllDownloads = false
    @State private var showLogoutConfirm = false

    /// Same speed steps as the full player's speed menu.
    private let availableRates: [Double] = [0.8, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        VStack(spacing: 0) {
            pillTabs
            Form {
                switch tab {
                case .general:
                    appearanceSection
                    storageSection
                    syncSection
                    serverSection
                    aboutSection
                case .audiobooks:
                    playbackSection
                    if availableLibraries.count > 1 { librarySection }
                    localFilesSection
                    statsSection
                case .podcasts:
                    podcastSourcesSection
                    podcastNotificationSection
                    podcastSyncSection
                }
            }
            .bottomBarClearance()
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task {
            coverCacheBytes = ImageCache.shared.cacheSizeBytes()
            pendingSyncCount = SyncQueue.shared.allPending().count
            if let libraries = try? await coordinator.provider.fetchLibraries() {
                // NUR Buch-Bibliotheken — Podcast-Libraries gehören zum
                // Podcast-Tab, nicht in die Hörbuch-Bibliotheksauswahl.
                availableLibraries = libraries.filter { !$0.isPodcast }
                // Reflect the effective library when nothing was chosen yet.
                if selectedLibraryId.isEmpty || !availableLibraries.contains(where: { $0.id == selectedLibraryId }) {
                    selectedLibraryId = availableLibraries.first?.id ?? ""
                }
            }
        }
        .alert("Delete all downloads?", isPresented: $showDeleteAllDownloads) {
            Button("Delete", role: .destructive) {
                DownloadManager.shared.deleteAllDownloads()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All downloaded audiobooks will be removed from this device. Listening progress is kept.")
        }
        .alert("Log out?", isPresented: $showLogoutConfirm) {
            Button("Log Out", role: .destructive) { onLogout() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The server address stays saved; the token is removed.")
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

    private var syncSection: some View {
        Section {
            LabeledContent {
                Text("\(pendingSyncCount)")
            } label: {
                Label("Pending Updates", systemImage: "arrow.triangle.2.circlepath")
            }
            Button {
                isSyncing = true
                Task {
                    await SyncQueue.shared.flush(apiClient: coordinator.provider)
                    pendingSyncCount = SyncQueue.shared.allPending().count
                    isSyncing = false
                }
            } label: {
                if isSyncing {
                    ProgressView()
                } else {
                    Label("Sync Now", systemImage: "arrow.clockwise")
                }
            }
            .disabled(pendingSyncCount == 0 || isSyncing)
        } header: {
            Text("Sync")
        } footer: {
            Text("Progress updates that could not reach the server yet are sent automatically as soon as possible.")
        }
    }

    private var serverSection: some View {
        Section("Server") {
            LabeledContent {
                Text(AppSession.shared.apiClient.baseURL.absoluteString)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } label: {
                Label("Address", systemImage: "server.rack")
            }
            Button(role: .destructive) {
                showLogoutConfirm = true
            } label: {
                Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
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

    // MARK: - Hörbücher

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
                    vm.setSkipInterval(newValue)   // aktualisiert auch die Lockscreen-Buttons
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

    private var librarySection: some View {
        Section("Library") {
            Picker(selection: $selectedLibraryId) {
                ForEach(availableLibraries) { library in
                    Text(library.name).tag(library.id)
                }
            } label: {
                Label("Library", systemImage: "books.vertical")
            }
            .onChange(of: selectedLibraryId) { _, _ in
                Task { await libraryViewModel?.loadLibrary() }
            }
        }
    }

    private var localFilesSection: some View {
        Section("Sources") {
            NavigationLink {
                LocalFilesView(onImported: {
                    Task { await libraryViewModel?.refreshAfterLocalChange() }
                })
            } label: {
                Label("Local Files", systemImage: "folder")
            }
        }
    }

    private var statsSection: some View {
        Section {
            NavigationLink {
                StatsView(libraryViewModel: libraryViewModel)
            } label: {
                Label("Statistics", systemImage: "chart.bar.fill")
            }
        }
    }

    // MARK: - Podcasts

    private var podcastSourcesSection: some View {
        Section("Sources") {
            NavigationLink {
                PodcastSourceView()
            } label: {
                Label("Podcasts", systemImage: "mic")
            }
        }
    }

    private var podcastNotificationSection: some View {
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
        } footer: {
            Text("Checks your subscriptions in the background and notifies you when new episodes are published. Requires notification permission.")
        }
    }

    private var podcastSyncSection: some View {
        Section {
            Toggle(isOn: $podcastICloudSync) {
                Label("Sync Podcast Progress via iCloud", systemImage: "icloud")
            }
            .onChange(of: podcastICloudSync) { _, on in
                if on { PodcastCloudSync.shared.start() }
            }
        } header: {
            Text("Sync")
        } footer: {
            Text("iCloud keeps podcast progress in sync across your own devices (needs iCloud enabled). Server-based podcast sync (gpodder, Audiobookshelf) is configured under Sources → Podcasts.")
        }
    }

    private static var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
        return "\(version) (\(build))"
    }
}
