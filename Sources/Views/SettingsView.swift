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
            Section("Wiedergabe") {
                Picker("Sprung-Intervall", selection: $skipInterval) {
                    ForEach([15.0, 30.0, 60.0], id: \.self) { seconds in
                        Text("\(Int(seconds)) Sekunden").tag(seconds)
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

            Section("Speicher") {
                LabeledContent("Downloads") {
                    Text(ByteCountFormatter.string(fromByteCount: downloadManager.totalDownloadsSize, countStyle: .file))
                }
                Button("Alle Downloads löschen", role: .destructive) {
                    showDeleteAllDownloads = true
                }
                .disabled(downloadManager.downloadedItemIds.isEmpty)

                LabeledContent("Cover-Cache") {
                    Text(ByteCountFormatter.string(fromByteCount: coverCacheBytes, countStyle: .file))
                }
                Button("Cover-Cache leeren") {
                    ImageCache.shared.clearCache()
                    coverCacheBytes = ImageCache.shared.cacheSizeBytes()
                }
            }

            Section("Server") {
                LabeledContent("Adresse") {
                    Text(coordinator.apiClient.baseURL.absoluteString)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Abmelden", role: .destructive) {
                    showLogoutConfirm = true
                }
            }
        }
        .navigationTitle("Einstellungen")
        .navigationBarTitleDisplayMode(.inline)
        .task { coverCacheBytes = ImageCache.shared.cacheSizeBytes() }
        .alert("Alle Downloads löschen?", isPresented: $showDeleteAllDownloads) {
            Button("Löschen", role: .destructive) {
                DownloadManager.shared.deleteAllDownloads()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Alle heruntergeladenen Hörbücher werden vom Gerät entfernt. Der Hörfortschritt bleibt erhalten.")
        }
        .alert("Abmelden?", isPresented: $showLogoutConfirm) {
            Button("Abmelden", role: .destructive) { onLogout() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Server-Adresse bleibt gespeichert; der Token wird entfernt.")
        }
    }
}
