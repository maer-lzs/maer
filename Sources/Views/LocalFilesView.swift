import SwiftUI
import UniformTypeIdentifiers

/// Verwaltung importierter lokaler Audiodateien: über den Datei-Picker
/// importieren (eine Auswahl = ein Hörbuch, mehrere Dateien werden zu einem
/// mehrteiligen Titel zusammengefasst), Liste mit Löschen. Die Wiedergabe
/// selbst läuft über die normale Bibliothek (LocalProvider mischt die
/// Einträge dort ein).
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
