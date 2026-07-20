// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

/// Management of imported local audio files: import via the file picker (one
/// selection = one audiobook, several files are combined into one multi-file
/// title), list with delete. Playback itself goes through the normal library
/// (LocalProvider mixes the entries in there).
struct LocalFilesView: View {
    @ObservedObject private var library = LocalLibrary.shared
    var onImported: (() -> Void)?

    @State private var showImporter = false
    @State private var isImporting = false

    var body: some View {
        List {
            Section {
                Button {
                    showImporter = true
                } label: {
                    Label("Import Audio Files", systemImage: "square.and.arrow.down")
                }
                .disabled(isImporting)
                if isImporting {
                    HStack {
                        ProgressView()
                        Text("Importing…").foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Pick one or more audio files. Multiple files selected together become a single multi-part audiobook.")
            }

            if !library.entries.isEmpty {
                Section("Imported") {
                    ForEach(library.entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).lineLimit(1)
                            if let author = entry.author {
                                Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { library.delete(id: library.entries[index].id) }
                        onImported?()
                    }
                }
            }
        }
        .navigationTitle("Local Files")
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            isImporting = true
            Task {
                await library.importFiles(urls)
                isImporting = false
                onImported?()
            }
        }
    }
}
