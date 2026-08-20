// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import Combine
import UIKit

/// Per-show settings: speed (used as the start rate), auto-download of new
/// episodes and sorting. Reachable via the show's slider icon.
struct PodcastShowSettingsSheet: View {
    let showId: String
    @Binding var newestFirst: Bool
    @Binding var unplayedOnly: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var rate: Float?          // nil = default speed
    @State private var autoDownloadMode = PodcastAutoDownload.Mode.off
    @State private var autoDownloadError: String?
    @State private var copiedReport = false
    @State private var inboxMode = "all"     // all | latest | off
    @State private var notify = true
    @State private var episodeLimit = 0      // 0 = unbegrenzt
    private let rates: [Float] = [0.8, 1.0, 1.1, 1.2, 1.5, 1.75, 2.0]
    private let limits: [Int] = [0, 5, 10, 25, 50, 100]

    /// Its own property because the `body` otherwise blows the type checker
    /// (measured: "unable to type-check this expression in reasonable time").
    @ViewBuilder
    private var diagnosisSection: some View {
        // The measuring instrument, NOT the fix. The cause is either a grown
        // duration or the sync, and only the stored timestamp separates the two
        // — it lives on the device, so the trigger belongs where the wrong
        // state shows up. Diagnostic UI stays verbatim (project convention).
        Section {
            Button {
                UIPasteboard.general.string = progressReport()
                copiedReport = true
            } label: {
                Label {
                    Text(verbatim: "Fortschritts-Diagnose kopieren")
                } icon: {
                    Image(systemName: "doc.on.clipboard")
                }
            }
            .accessibilityIdentifier("progress-diagnosis-copy")
            if copiedReport {
                Text(verbatim: "In die Zwischenablage gelegt.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text(verbatim: "Diagnose")
        } footer: {
            Text(verbatim: "Positionen, Zeitstempel und die heute gemeldete Dauer dieser Sendung — zum Weitergeben, wenn eine gehoerte Folge wieder als angefangen erscheint.")
        }
    }

    /// Collects this show's stored positions — read-only.
    private func progressReport() -> String {
        let show = PodcastSubscriptions.shared.shows.first { $0.id == showId }
            ?? ABSPodcastProvider.shared.shows.first { $0.id == showId }
        let defaults = UserDefaults.standard
        let entries: [ProgressDiagnosis.Entry] = (show?.episodes ?? []).compactMap { episode in
            guard let stored = ListeningStore.backup(episode.guid, in: defaults),
                  stored.count >= 2, stored[0] > 0 else { return nil }
            return ProgressDiagnosis.Entry(
                title: episode.title, guid: episode.guid,
                position: stored[0],
                // The stored timestamp is in milliseconds.
                updatedAt: stored[1] / 1000,
                feedDuration: episode.duration,
                markedDuration: ProgressMark.markedDuration(stored))
        }
        let lastSync = SyncHistoryStore.shared.lastChecked[SyncHistoryEntry.Service.gpodder.rawValue]
        return ProgressDiagnosis.report(
            show: show?.title ?? showId,
            entries: entries,
            lastSync: lastSync?.timeIntervalSince1970,
            now: Date().timeIntervalSince1970,
            format: { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .standard) })
    }

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
                    AppSwitch("Notify About New Episodes", isOn: $notify)
                } header: {
                    Text("New Episodes")
                } footer: {
                    Text("For high-frequency shows, set this to Latest only or Off so they don't flood New Episodes, and turn off notifications.")
                }
                Section {
                    // A choice, not a direction for everyone: news shows want
                    // the newest, a backlog wants the beginning.
                    Picker("Auto-download", selection: $autoDownloadMode) {
                        Text("Off").tag(PodcastAutoDownload.Mode.off)
                        Text("Newest episodes").tag(PodcastAutoDownload.Mode.newest)
                        Text("In order (from the start)").tag(PodcastAutoDownload.Mode.inOrder)
                    }
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
                diagnosisSection

                Section("Sort") {
                    Picker("Order", selection: $newestFirst) {
                        Label("Newest First", systemImage: "arrow.down").tag(true)
                        Label("Oldest First", systemImage: "arrow.up").tag(false)
                    }
                    .pickerStyle(.inline)
                    // The filter lives WITH the sort — both answer "what does
                    // this show's list display", both remembered per show.
                    Picker("Filter", selection: $unplayedOnly) {
                        Label("All Episodes", systemImage: "circle.grid.2x2").tag(false)
                        Label("Unplayed Only", systemImage: "circle").tag(true)
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
                autoDownloadMode = PodcastAutoDownload.mode(showId)
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
            .onChange(of: autoDownloadMode) { _, mode in
                PodcastAutoDownload.setMode(showId, mode)
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
