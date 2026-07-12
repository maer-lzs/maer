import SwiftUI
import Combine

/// Pro-Show-Einstellungen: Tempo (greift als Start-Rate), Auto-Download neuer
/// Folgen und Sortierung. Erreichbar über das Schieberegler-Symbol der Show.
struct PodcastShowSettingsSheet: View {
    let showId: String
    @Binding var newestFirst: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var rate: Float?          // nil = Standard-Tempo
    @State private var autoDownload = false
    private let rates: [Float] = [0.8, 1.0, 1.1, 1.2, 1.5, 1.75, 2.0]

    var body: some View {
        NavigationStack {
            Form {
                Section("Playback Speed") {
                    Picker("Speed", selection: $rate) {
                        Text("Default").tag(Float?.none)
                        ForEach(rates, id: \.self) { r in
                            Text(String(format: "%g×", r)).tag(Float?.some(r))
                        }
                    }
                }
                Section {
                    Toggle("Auto-download new episodes", isOn: $autoDownload)
                } footer: {
                    Text("Newly published episodes are downloaded to this device automatically.")
                }
                Section("Sort") {
                    Picker("Order", selection: $newestFirst) {
                        Label("Newest First", systemImage: "arrow.down").tag(true)
                        Label("Oldest First", systemImage: "arrow.up").tag(false)
                    }
                    .pickerStyle(.inline)
                }
            }
            .navigationTitle("Podcast Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear {
                rate = UserDefaults.standard.object(forKey: AppStorageKeys.podcastShowRate(showId)) as? Float
                autoDownload = PodcastAutoDownload.isEnabled(showId)
            }
            .onChange(of: rate) { _, new in
                let key = AppStorageKeys.podcastShowRate(showId)
                if let new { UserDefaults.standard.set(new, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            .onChange(of: autoDownload) { _, on in
                PodcastAutoDownload.setEnabled(showId, on)
            }
        }
    }
}
