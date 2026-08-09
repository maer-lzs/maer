// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import Combine

/// Per-show settings: speed (used as the start rate), auto-download of new
/// episodes and sorting. Reachable via the show's slider icon.
struct PodcastShowSettingsSheet: View {
    let showId: String
    @Binding var newestFirst: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var rate: Float?          // nil = default speed
    @State private var autoDownload = false
    @State private var autoDownloadError: String?
    @State private var inboxMode = "all"     // all | latest | off
    @State private var notify = true
    @State private var episodeLimit = 0      // 0 = unbegrenzt
    private let rates: [Float] = [0.8, 1.0, 1.1, 1.2, 1.5, 1.75, 2.0]
    private let limits: [Int] = [0, 5, 10, 25, 50, 100]

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
                    Picker("Show in New Episodes", selection: $inboxMode) {
                        Text("All").tag("all")
                        Text("Latest only").tag("latest")
                        Text("Off").tag("off")
                    }
                    Toggle("Notify About New Episodes", isOn: $notify)
                } header: {
                    Text("New Episodes")
                } footer: {
                    Text("For high-frequency shows, set this to Latest only or Off so they don't flood New Episodes, and turn off notifications.")
                }
                Section {
                    Toggle("Auto-download new episodes", isOn: $autoDownload)
                    Picker("Keep only latest", selection: $episodeLimit) {
                        ForEach(limits, id: \.self) { n in
                            Text(n == 0 ? String(localized: "All") : "\(n)").tag(n)
                        }
                    }
                } header: {
                    Text("Episodes")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Automatic downloads only run on Wi-Fi, and are removed a week after you finished them — episodes you downloaded yourself are never touched. Keeping only the latest N removes older episodes (and their downloads) from this show.")
                        // Regel 3: a background job that failed says so where
                        // it was switched on, and says why.
                        if let failure = autoDownloadError {
                            Text(failure).foregroundStyle(.red)
                        }
                    }
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
                autoDownloadError = PodcastAutoDownload.lastError(showId)
                inboxMode = AppStorageKeys.podcastInboxModeValue(showId)
                notify = AppStorageKeys.podcastNotifyEnabled(showId)
                episodeLimit = AppStorageKeys.podcastEpisodeLimitValue(showId)
            }
            .onChange(of: rate) { _, new in
                let key = AppStorageKeys.podcastShowRate(showId)
                if let new { UserDefaults.standard.set(new, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            .onChange(of: autoDownload) { _, on in
                PodcastAutoDownload.setEnabled(showId, on)
            }
            .onChange(of: inboxMode) { _, m in
                UserDefaults.standard.set(m, forKey: AppStorageKeys.podcastInboxMode(showId))
            }
            .onChange(of: notify) { _, on in
                UserDefaults.standard.set(on, forKey: AppStorageKeys.podcastNotify(showId))
            }
            .onChange(of: episodeLimit) { _, n in
                UserDefaults.standard.set(n, forKey: AppStorageKeys.podcastEpisodeLimit(showId))
                // Apply immediately so the show page gets leaner right away.
                Task { await PodcastSubscriptions.shared.trimEpisodes(showId: showId, keepLatest: n) }
            }
        }
    }
}
