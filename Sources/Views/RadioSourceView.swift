// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The radio source page: the stations entered by hand (name + URL). The
/// Radio Browser directory has its one switch on the radio card of the
/// sources (`SourceMapCard`), not here.
struct RadioSourceView: View {
    @State private var manualStations: [RadioStation] = []
    @State private var newName = ""
    @State private var newURL = ""
    @State private var addError: String?

    var body: some View {
        Form {
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
                        RadioStore.removeManualNoting(manualStations[offset].id)
                    }
                    manualStations = RadioStore.manualStations()
                }

                TextField("Name", text: $newName)
                    .accessibilityIdentifier("radio-manual-name")
                TextField("Stream URL", text: $newURL)
                    .accessibilityIdentifier("radio-manual-url")
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button {
                    guard let station = RadioMapping.manualStation(name: newName, urlString: newURL) else {
                        addError = String(localized: "Enter a name and a valid stream URL (http/https).")
                        return
                    }
                    RadioStore.addManualNoting(station)
                    manualStations = RadioStore.manualStations()
                    newName = ""
                    newURL = ""
                    addError = nil
                } label: {
                    Label("Add Station", systemImage: "plus")
                }
                .accessibilityIdentifier("radio-manual-add")
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || newURL.isEmpty)
                if let addError {
                    Text(addError).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Your Own Stations")
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
