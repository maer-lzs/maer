import SwiftUI

/// Zentrale Einstellungen: Wiedergabe, Darstellung, Downloads/Speicher,
/// Sync, Server/Abmelden, App-Info.
struct SettingsView: View {
    @ObservedObject var coordinator: PlayerCoordinator
    /// For reloading after a library switch — the settings are pushed from
    /// the library screen, which owns this view model.
    var libraryViewModel: LibraryViewModel? = nil
    @ObservedObject private var downloadManager = DownloadManager.shared
    let onLogout: () -> Void

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
        Form {
            playbackSection
            appearanceSection
            sourcesSection
            downloadsSection
            syncSection
            statsSection
            serverSection
            aboutSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            coverCacheBytes = ImageCache.shared.cacheSizeBytes()
            pendingSyncCount = SyncQueue.shared.allPending().count
            if let libraries = try? await coordinator.provider.fetchLibraries() {
                availableLibraries = libraries
                // Reflect the effective library when nothing was chosen yet.
                if selectedLibraryId.isEmpty || !libraries.contains(where: { $0.id == selectedLibraryId }) {
                    selectedLibraryId = libraries.first?.id ?? ""
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

    // MARK: - Wiedergabe

    private var playbackSection: some View {
        Section {
            Picker("Skip Interval", selection: $skipInterval) {
                ForEach([15.0, 30.0, 60.0], id: \.self) { seconds in
                    Text("\(Int(seconds)) seconds").tag(seconds)
                }
            }
            .onChange(of: skipInterval) { _, newValue in
                if let vm = coordinator.viewModel {
                    // Aktive Session: aktualisiert auch die Lockscreen-Buttons.
                    vm.setSkipInterval(newValue)
                } else {
                    UserDefaults.standard.set(newValue, forKey: AppStorageKeys.skipInterval)
                }
            }

            Picker("Default Speed", selection: $defaultRate) {
                ForEach(availableRates, id: \.self) { rate in
                    Text("\(rate.formatted(.number.precision(.fractionLength(0...2))))×").tag(rate)
                }
            }
            .onChange(of: defaultRate) { _, newValue in
                UserDefaults.standard.set(Float(newValue), forKey: AppStorageKeys.defaultPlaybackRate)
            }

            Toggle("Smart Rewind", isOn: $smartRewind)
                .onChange(of: smartRewind) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: AppStorageKeys.smartRewind)
                }

            Toggle("Auto-Play Next in Series", isOn: $autoPlayNext)
                .onChange(of: autoPlayNext) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: AppStorageKeys.autoPlayNextInSeries)
                }
        } header: {
            Text("Playback")
        } footer: {
            Text("New books start at the default speed. Smart Rewind resumes a little earlier after a longer pause. When a series book ends, the next unfinished one starts automatically.")
        }
    }

    // MARK: - Darstellung

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Appearance", selection: $appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Downloads & Speicher

    private var downloadsSection: some View {
        Section {
            Toggle("Warn When Not on Wi-Fi", isOn: $warnCellular)
                .onChange(of: warnCellular) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: AppStorageKeys.warnCellularDownload)
                }

            LabeledContent("Downloads") {
                Text(ByteCountFormatter.string(fromByteCount: downloadManager.totalDownloadsSize, countStyle: .file))
            }
            Button("Delete All Downloads", role: .destructive) {
                showDeleteAllDownloads = true
            }
            .disabled(downloadManager.downloadedItemIds.isEmpty)

            LabeledContent("Cover Cache") {
                Text(ByteCountFormatter.string(fromByteCount: coverCacheBytes, countStyle: .file))
            }
            Button("Clear Cover Cache") {
                ImageCache.shared.clearCache()
                coverCacheBytes = ImageCache.shared.cacheSizeBytes()
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Deleting downloads never deletes listening progress.")
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        Section {
            LabeledContent("Pending Updates") {
                Text("\(pendingSyncCount)")
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
                    Text("Sync Now")
                }
            }
            .disabled(pendingSyncCount == 0 || isSyncing)
        } header: {
            Text("Sync")
        } footer: {
            Text("Progress updates that could not reach the server yet are sent automatically as soon as possible.")
        }
    }

    private var sourcesSection: some View {
        Section("Sources") {
            NavigationLink {
                LocalFilesView(onImported: {
                    Task { await libraryViewModel?.refreshAfterLocalChange() }
                })
            } label: {
                Label("Local Files", systemImage: "folder")
            }
            NavigationLink {
                PodcastSourceView()
            } label: {
                Label("Podcasts", systemImage: "mic")
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

    // MARK: - Server

    private var serverSection: some View {
        Section("Server") {
            LabeledContent("Address") {
                Text(AppSession.shared.apiClient.baseURL.absoluteString)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // Only shown when the server actually has several libraries —
            // with a single one the picker would just be noise.
            if availableLibraries.count > 1 {
                Picker("Library", selection: $selectedLibraryId) {
                    ForEach(availableLibraries) { library in
                        Text(library.name).tag(library.id)
                    }
                }
                .onChange(of: selectedLibraryId) { _, _ in
                    Task { await libraryViewModel?.loadLibrary() }
                }
            }
            Button("Log Out", role: .destructive) {
                showLogoutConfirm = true
            }
        }
    }

    // MARK: - App-Info

    private var aboutSection: some View {
        Section {
            LabeledContent("Version") {
                Text(Self.versionString)
            }
        } footer: {
            Text("Mär is an unofficial client for Audiobookshelf.")
        }
    }

    private static var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
        return "\(version) (\(build))"
    }
}
