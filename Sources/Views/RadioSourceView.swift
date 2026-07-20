// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// F1/F4: the radio source page — the shared source pattern (Etappe E):
/// toggle + the manual stream list (name + URL). The catalog needs no
/// account: Radio Browser is an open, key-free community directory.
struct RadioSourceView: View {
    @AppStorage(AppStorageKeys.radioEnabled) private var enabled = false
    @State private var manualStations: [RadioStation] = []
    @State private var newName = ""
    @State private var newURL = ""
    @State private var addError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Show Radio tab", isOn: $enabled)
                    // Locale-independent handle for the UI-test harness.
                    .accessibilityIdentifier("radio-tab-toggle")
                    // Y37 pattern: the toggle acts immediately, the tab bar
                    // reacts live in both directions.
                    .onChange(of: enabled) { _, _ in
                        AppSession.shared.notifySourcesChanged()
                    }
            } footer: {
                Text("Stations come from the open Radio Browser directory (no account) and from your own stream URLs below.")
            }

            Section {
                ForEach(manualStations) { station in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(station.name)
                        Text(station.streamURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .onDelete { offsets in
                    for offset in offsets {
                        RadioStore.removeManual(manualStations[offset].id)
                    }
                    manualStations = RadioStore.manualStations()
                }

                TextField("Name", text: $newName)
                TextField("Stream URL", text: $newURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button {
                    guard let station = RadioMapping.manualStation(name: newName, urlString: newURL) else {
                        addError = String(localized: "Enter a name and a valid stream URL (http/https).")
                        return
                    }
                    RadioStore.addManual(station)
                    manualStations = RadioStore.manualStations()
                    newName = ""
                    newURL = ""
                    addError = nil
                } label: {
                    Label("Add Station", systemImage: "plus")
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || newURL.isEmpty)
                if let addError {
                    Text(addError).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("My Streams")
            } footer: {
                Text("Direct stream URLs (e.g. from your AzuraCast or Icecast server) play like any catalog station.")
            }
        }
        .navigationTitle("Radio")
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
        .onAppear { manualStations = RadioStore.manualStations() }
    }
}
