import SwiftUI

/// Zentrale Einstellungen: Wiedergabe, Speicher, Server/Abmelden.
struct SettingsView: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject private var downloadManager = DownloadManager.shared
    let onLogout: () -> Void

    @State private var skipInterval: Double =
        UserDefaults.standard.object(forKey: AppStorageKeys.skipInterval) as? Double ?? 30
    @State private var coverCacheBytes: Int64 = 0
    @State private var showDeleteAllDownloads = false
    @State private var showLogoutConfirm = false

    var body: some View {
        Form {
            Section("Playback") {
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
            }

            Section("Storage") {
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
            }

            Section("Server") {
                LabeledContent("Address") {
                    Text(coordinator.apiClient.baseURL.absoluteString)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Log Out", role: .destructive) {
                    showLogoutConfirm = true
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { coverCacheBytes = ImageCache.shared.cacheSizeBytes() }
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
}
