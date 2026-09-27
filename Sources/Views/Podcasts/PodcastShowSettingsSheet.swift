// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import Combine
import UIKit

/// The slider that opens a show's settings. One button for the show page and
/// the episode page, so both carry the same sign and VoiceOver hears a word.
struct PodcastShowSettingsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "slider.horizontal.3") }
            .accessibilityLabel(Text("Settings"))
    }
}

/// The sheet for a place that does not own the show's list, the episode
/// page. It reads sort and filter through the one store rule and writes every
/// change back through it. It opens only for a show in a store, so the show
/// counts as subscribed.
struct PodcastShowSettingsEntry: View {
    let show: PodcastShow
    @State private var preferences = PodcastShowPreferences.default

    var body: some View {
        PodcastShowSettingsSheet(
            show: show,
            newestFirst: PodcastShowPreferences.binding(\.newestFirst, of: $preferences,
                                                        showId: show.id, mode: .subscribed),
            unplayedOnly: PodcastShowPreferences.binding(\.unplayedOnly, of: $preferences,
                                                         showId: show.id, mode: .subscribed))
            .task(id: show.id) {
                preferences = PodcastShowPreferences.load(showId: show.id, mode: .subscribed)
            }
            // The same read again when another device changed the sort or filter.
            .onReceive(NotificationCenter.default.publisher(for: .userChoicesAdopted)) { note in
                guard PodcastShowPreferences.adoptionTouches(PodcastShowPreferences.adoptedKeys(note.userInfo),
                                                             showId: show.id) else { return }
                preferences = PodcastShowPreferences.load(showId: show.id, mode: .subscribed)
            }
    }
}

extension PodcastShowPreferences {
    /// One choice of a show's page as a binding: every change runs through
    /// the ONE store rule, which in the browsed state writes nothing.
    static func binding(_ path: WritableKeyPath<PodcastShowPreferences, Bool>,
                        of preferences: Binding<PodcastShowPreferences>,
                        showId: String, mode: PodcastShowMode,
                        defaults: UserDefaults = .standard,
                        note: @escaping @MainActor (Any?, String) -> Void = { AppStorageKeys.noteChoice($0, key: $1) }) -> Binding<Bool> {
        Binding(
            get: { preferences.wrappedValue[keyPath: path] },
            set: { newValue in
                preferences.wrappedValue[keyPath: path] = newValue
                preferences.wrappedValue.store(path, showId: showId, mode: mode, defaults: defaults, note: note)
            })
    }
}

/// Per-show settings: speed (used as the start rate), auto-download of new
/// episodes and sorting. Reachable via the show's slider icon, on the show
/// page and on each of its episodes.
struct PodcastShowSettingsSheet: View {
    let show: PodcastShow
    @Binding var newestFirst: Bool
    @Binding var unplayedOnly: Bool
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .headline) private var coverSize: CGFloat = 44
    private var showId: String { show.id }
    @State private var rate: Float?          // nil = default speed
    @State private var autoDownloadError: String?
    @State private var copiedReport = false
    @State private var notify = true
    /// The show's own value per field; a missing field follows all shows.
    @State private var own: [PodcastGeneralField: String] = [:]
    private let rates: [Float] = [0.8, 1.0, 1.1, 1.2, 1.5, 1.75, 2.0]

    /// One of the three values a show can take from all shows. The
    /// first choice is "As for all shows", the way back from its own value.
    private func generalPicker(_ field: PodcastGeneralField) -> some View {
        Picker(field.name, selection: ownBinding(field)) {
            Text("As for all shows (\(field.label(field.general)))").tag(String?.none)
            ForEach(field.choices, id: \.self) { raw in
                Text(field.label(raw)).tag(String?.some(raw))
            }
        }
        .choicesAsRowsWhenLarge()
    }

    /// Writes only from the hand: a binding's `set` runs when the picker is
    /// used, never when the sheet fills itself (GT-14).
    private func ownBinding(_ field: PodcastGeneralField) -> Binding<String?> {
        Binding(
            get: { own[field] },
            set: { raw in
                guard raw != field.stored(showId) else { return }
                if let raw { field.setOwn(raw, showId: showId) } else { field.clear(showId) }
                own[field] = field.stored(showId)
            })
    }

    /// Its own property because the `body` otherwise blows the type checker
    /// (measured: "unable to type-check this expression in reasonable time").
    @ViewBuilder
    private var diagnosisSection: some View {
        // The measuring instrument, NOT the fix. The cause is either a grown
        // duration or the sync, and only the stored timestamp separates the two.
        // It lives on the device, so the trigger belongs where the wrong
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
            Text(verbatim: "Positionen, Zeitstempel und die heute gemeldete Dauer dieser Sendung, zum Weitergeben, wenn eine gehoerte Folge wieder als angefangen erscheint.")
        }
    }

    /// Collects this show's stored positions. Read-only.
    private func progressReport() -> String {
        let show = PodcastSubscriptions.shared.shows.first { $0.id == showId }
            ?? ABSPodcastProvider.shared.shows.first { $0.id == showId }
        let entries: [ProgressDiagnosis.Entry] = (show?.episodes ?? []).compactMap { episode in
            guard let stored = ListeningStore.backup(episode.guid),
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
        let format: (Double) -> String = { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .standard) }
        let report = ProgressDiagnosis.report(
            show: show?.title ?? showId,
            entries: entries,
            lastSync: lastSync?.timeIntervalSince1970,
            now: Date().timeIntervalSince1970,
            format: format)
        // The automatism's own state on THIS device (it does not travel), so
        // a report from the device says which direction the runs read.
        return report + "\n" + PodcastAutoDownload.stateLine(showId, format: format)
    }

    var body: some View {
        NavigationStack {
            Form {
                // The show stands as the first row, whole at every text
                // size. In the title a long name was cut at large text.
                Section {
                    HStack(spacing: 12) {
                        podcastArtwork(url: show.artworkURL.flatMap { URL(string: $0) },
                                       size: coverSize, corner: 8)
                            .accessibilityHidden(true)
                        Text(show.title).font(.headline)
                    }
                }
                Section("Playback Speed") {
                    Picker("Speed", selection: $rate) {
                        Text("Default").tag(Float?.none)
                        ForEach(rates, id: \.self) { r in
                            Text(String(format: "%g×", r)).tag(Float?.some(r))
                        }
                    }
                }
                Section {
                    generalPicker(.newEpisodes)
                    AppSwitch("Notify About New Episodes", isOn: $notify)
                } header: {
                    Text("New Episodes")
                } footer: {
                    Text("For high-frequency shows, set this to Latest only or Off so they don't flood New Episodes, and turn off notifications.")
                }
                Section {
                    // A choice, not a direction for everyone: news shows want
                    // the newest, a backlog wants the beginning.
                    generalPicker(.autoDownload)
                    generalPicker(.direction)
                    generalPicker(.keepDownloaded)
                } header: {
                    Text("Episodes")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Automatic downloads only run on Wi-Fi, and are removed a day after you finished them. Episodes you downloaded yourself are never touched.")
                        // A background job that failed says so where
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
                    // The filter lives WITH the sort. Both answer "what does
                    // this show's list display", both remembered per show.
                    Picker("Filter", selection: $unplayedOnly) {
                        Label("All Episodes", systemImage: "circle.grid.2x2").tag(false)
                        Label("Unplayed Only", systemImage: "circle").tag(true)
                    }
                    .pickerStyle(.inline)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { reloadFromStore() }
            // Another device changed one of this show's values: the sheet
            // shows the stored state, also while it is open (decided).
            .onReceive(NotificationCenter.default.publisher(for: .userChoicesAdopted)) { note in
                guard PodcastShowPreferences.adoptionTouches(PodcastShowPreferences.adoptedKeys(note.userInfo),
                                                             showId: showId) else { return }
                reloadFromStore()
            }
            // Each field writes only a CHANGE. The load above sets every
            // state, and each `onChange` fired on it and wrote the value
            // straight back: the travelling ones stamped "now" without anyone
            // touching them, and "Newest" moved its cutoff to the moment the
            // sheet was opened (GT-14). Mechanics never stamp. The three
            // values a show can take from all shows write through
            // `ownBinding` instead, which only the hand reaches.
            .onChange(of: rate) { _, new in
                guard new != AppStorageKeys.float(AppStorageKeys.podcastShowRate(showId)) else { return }
                AppStorageKeys.setPodcastShowRate(new, showId: showId)
            }
            .onChange(of: notify) { _, on in
                guard on != AppStorageKeys.podcastNotifyEnabled(showId) else { return }
                AppStorageKeys.setPodcastNotify(on, showId: showId)
            }
        }
    }

    /// Every state of the sheet from the store. Only reads: the `onChange`
    /// guards above find the stored value equal and write nothing.
    private func reloadFromStore() {
        rate = AppStorageKeys.float(AppStorageKeys.podcastShowRate(showId))
        autoDownloadError = PodcastAutoDownload.lastError(showId)
        notify = AppStorageKeys.podcastNotifyEnabled(showId)
        for field in PodcastGeneralField.allCases { own[field] = field.stored(showId) }
    }
}
