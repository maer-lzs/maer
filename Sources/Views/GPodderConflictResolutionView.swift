// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Resolve a gpodder subscription conflict the mass-delete guard left blocked:
/// show the feeds that differ between THIS device and the SERVER and let the
/// user converge them deliberately (per feed or in bulk). Nothing is applied
/// until "Apply". Default pre-selection = UNION (keep everything, nothing lost).
struct GPodderConflictResolutionView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var snapshot: GPodderSync.ConflictSnapshot?
    /// Per conflicting feed: keep it in the converged state? (default true = union)
    @State private var keep: [String: Bool] = [:]
    @State private var loading = true
    @State private var applying = false
    // #43 apply-regression: load and apply failures are semantically different
    // errors. One shared string made the full-screen load branch swallow the
    // conflict list after a failed Apply. Keep them as separate states.
    /// Snapshot could not be fetched. There IS no conflict list to show.
    @State private var loadErrorText: String?
    /// Apply failed. The list, selection and retry must STAY visible.
    @State private var applyErrorText: String?

    private var localOnly: [String] {
        guard let s = snapshot else { return [] }
        return s.localNorms.subtracting(s.serverNorms).sorted()
    }
    private var serverOnly: [String] {
        guard let s = snapshot else { return [] }
        return s.serverNorms.subtracting(s.localNorms).sorted()
    }
    private var hasConflict: Bool { !localOnly.isEmpty || !serverOnly.isEmpty }

    var body: some View {
        Form {
            if loading {
                Section { HStack { ProgressView(); Text("Loading subscriptions…") } }
            } else if let loadErrorText {
                // The load-error branch must come BEFORE the no-conflict
                // branch. A failed snapshot (server unreachable) used to fall
                // into the green "No differences" path and read as "in sync".
                Section { Label(loadErrorText, systemImage: "xmark.octagon").foregroundStyle(.red) }
            } else if !hasConflict {
                Section {
                    Label("No differences — this device and the server already match.",
                          systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            } else {
                Section {
                    Button("Keep everything (union)") { setAll(localKeep: true, serverKeep: true) }
                    Button("Keep only this device's") { setAll(localKeep: true, serverKeep: false) }
                    Button("Keep only the server's") { setAll(localKeep: false, serverKeep: true) }
                } header: {
                    Text("Resolve all")
                } footer: {
                    Text("Choose per feed below, or set all at once. Nothing changes until you tap Apply.")
                }

                if !localOnly.isEmpty {
                    Section("Only on this device") {
                        ForEach(localOnly, id: \.self) { feed in
                            feedToggle(feed, raw: snapshot?.localRaw[feed])
                        }
                    }
                }
                if !serverOnly.isEmpty {
                    Section("Only on the server") {
                        ForEach(serverOnly, id: \.self) { feed in
                            feedToggle(feed, raw: snapshot?.serverRaw[feed])
                        }
                    }
                }

                if let applyErrorText {
                    Section { Label(applyErrorText, systemImage: "xmark.octagon").foregroundStyle(.red) }
                }

                Section {
                    Button {
                        Task { await apply() }
                    } label: {
                        HStack {
                            if applying { ProgressView() }
                            Text("Apply")
                        }
                    }
                    .disabled(applying)
                }
            }
        }
        .navigationTitle("Resolve Conflict")
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
        .task { await load() }
    }

    private func feedToggle(_ feed: String, raw: String?) -> some View {
        AppSwitch(isOn: Binding(
            get: { keep[feed] ?? true },
            set: { keep[feed] = $0 }
        )) {
            Text(displayName(feed: feed, raw: raw)).lineLimit(2)
        }
    }

    /// Prefer a subscribed show's title (local feeds); else a compact URL.
    private func displayName(feed: String, raw: String?) -> String {
        if let show = PodcastSubscriptions.shared.shows.first(where: {
            PodcastSubscriptions.normalizeFeedURL($0.feedURL) == feed
        }), !show.title.isEmpty {
            return show.title
        }
        guard let raw, let url = URL(string: raw) else { return raw ?? feed }
        return (url.host ?? "") + url.path
    }

    private func setAll(localKeep: Bool, serverKeep: Bool) {
        for f in localOnly { keep[f] = localKeep }
        for f in serverOnly { keep[f] = serverKeep }
    }

    private func load() async {
        loading = true
        snapshot = await GPodderSync.shared.conflictSnapshot()
        if snapshot == nil { loadErrorText = String(localized: "Couldn't reach the gpodder server.") }
        loading = false
    }

    private func apply() async {
        guard let s = snapshot else { return }
        applying = true
        applyErrorText = nil
        // Map the per-feed "keep" toggles to the pure resolution choices.
        var choices: [String: GPodderConflictResolution.Choice] = [:]
        for feed in localOnly {   // local-only: keep = keepLocal (push), else takeServer (drop)
            choices[feed] = (keep[feed] ?? true) ? .keepLocal : .takeServer
        }
        for feed in serverOnly {  // server-only: keep = takeServer (subscribe), else keepLocal (drop)
            choices[feed] = (keep[feed] ?? true) ? .takeServer : .keepLocal
        }
        let actions = GPodderConflictResolution.resolve(
            local: s.localNorms, server: s.serverNorms, choices: choices)
        if let err = await GPodderSync.shared.applyConflictResolution(actions, snapshot: s) {
            applyErrorText = err
            applying = false
        } else {
            applying = false
            dismiss()
        }
    }
}
