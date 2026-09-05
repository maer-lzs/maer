// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The rights capsule + source backlink of a catalog title. ONE truth for
/// the book detail page and the music sheet: the licence the source
/// states, else the computed rights note; never a blanket badge (an
/// Old-Time-Radio item can be CC-BY-NC-ND, and a checkmark IS an
/// assertion).
struct CatalogRightsSection: View {
    let item: LibraryItem

    private var librivoxURL: URL? {
        FreeCatalogProvider.shared.librivoxBook(forId: item.id)?.url_librivox
            .flatMap { URL(string: $0) }
    }

    var body: some View {
        VStack(spacing: 6) {
            if let licence = FreeCatalogProvider.shared.licence(forItemId: item.id) {
                Label(licence, systemImage: "checkmark.seal")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                switch FreeCatalog.rightsNote(
                    year: item.media?.metadata?.publishedYear?.value) {
                case .publicDomain:
                    Label("Public domain", systemImage: "checkmark.seal")
                        .font(.caption).foregroundStyle(.secondary)
                case .termsApply(let year):
                    // A fact about TERMS, never a verdict about this title:
                    // the answer differs by country, and the device region
                    // is not the listener's jurisdiction.
                    Label(String(localized: "Recording from \(year). Sound recordings are free after 50 years in Switzerland, 70 in the EU and 100 in the USA."),
                          systemImage: "clock")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .unknown:
                    Label("Rights status not stated by the source",
                          systemImage: "questionmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let url = librivoxURL {
                Link(destination: url) {
                    Label("View on LibriVox", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
            } else if item.id.hasPrefix(FreeCatalog.archivePrefix),
                      let identifier = FreeCatalog.archiveIdentifier(of: item.id),
                      let url = URL(string: "https://archive.org/details/\(FreeCatalog.encodedPathSegment(identifier))") {
                Link(destination: url) {
                    Label("View on Internet Archive", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Take a LibriVox book into the library: ABS upload (with a connected
/// audiobook library) or a LOCAL feed subscription. The whole machinery
/// (menu, progress, Wi-Fi gate, library picker) as ONE component, so the
/// detail page carries exactly what the sheet carried.
struct LibriVoxTakeoverSection: View {
    let item: LibraryItem
    @ObservedObject private var importer = LibriVoxImporter.shared
    @State private var absLibraries: [ABSLibrary] = []
    @State private var showLibraryPicker = false
    @State private var showWiFiWarning = false
    @State private var localSubscribed = false

    private var book: LibriVoxBook? {
        FreeCatalogProvider.shared.librivoxBook(forId: item.id)
    }

    var body: some View {
        importSection
            .task { absLibraries = await LibriVoxImporter.audiobookLibraries() }
            // Library picker (first use / vanished remembered target). The
            // choice is remembered; the folder is the library's first (ABS
            // libraries practically always carry exactly one).
            .confirmationDialog("Choose the target library", isPresented: $showLibraryPicker,
                                titleVisibility: .visible) {
                ForEach(absLibraries) { library in
                    Button(library.name) {
                        Task {
                            var folderId = library.folders?.first?.id
                            if folderId == nil {
                                folderId = (try? await AppSession.shared.apiClient
                                    .fetchLibraryFolders(libraryId: library.id))?.first?.id
                            }
                            guard let folderId else { return }
                            AppStorageKeys.set(library.id, for: AppStorageKeys.librivoxImportLibraryId)
                            AppStorageKeys.set(folderId, for: AppStorageKeys.librivoxImportFolderId)
                            begin(libraryId: library.id, folderId: folderId)
                        }
                    }
                }
            }
            .alert("Not on Wi-Fi", isPresented: $showWiFiWarning) {
                Button("Continue on Cellular", role: .destructive) {
                    Task { await pickLibraryAndStart() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Audiobooks are large (often several hundred MB). Continue on cellular data?")
            }
    }

    @ViewBuilder
    private var importSection: some View {
        switch importer.phase {
        case .downloading(let section, let of) where importer.activeBookId == item.id:
            VStack(spacing: 6) {
                // The detail shows the SAME ring as the tile (one progress
                // language), the part line stays as the detail text.
                UnifiedDownloadRing(fraction: LibriVoxImporter.ringFraction(importer.phase) ?? -1,
                                    lineWidth: 3, tint: .accentColor)
                    .frame(width: 34, height: 34)
                Text("Downloading part \(section) of \(of)…")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Cancel", role: .cancel) { importer.cancel() }
                    .font(.caption)
            }
        case .uploading where importer.activeBookId == item.id:
            VStack(spacing: 6) {
                ProgressView()
                Text("Uploading to your server…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        // Terminal states belong to THEIR book only. A foreign page falls
        // through to the menu below.
        case .done where importer.activeBookId == item.id:
            Label("Added to your library.", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .duplicate(let existing) where importer.activeBookId == item.id:
            Label("Already in that library: \(existing)", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let message) where importer.activeBookId == item.id:
            // The retry path. Back to the menu on demand.
            VStack(spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                Button("Try Again") { importer.reset() }
                    .font(.caption)
            }
        default:
            if importer.busy {
                // A second import while one runs: clear refusal, no ghost UI.
                Label("Another import is already running.", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Menu {
                    if !absLibraries.isEmpty {
                        Button {
                            startServerImport()
                        } label: {
                            Label("To my server (Audiobookshelf)", systemImage: "square.and.arrow.up.on.square")
                        }
                    }
                    if book?.url_rss?.isEmpty == false {
                        Button {
                            subscribeLocally()
                        } label: {
                            Label("Subscribe as feed (local only)", systemImage: "dot.radiowaves.up.forward")
                        }
                    }
                } label: {
                    Label(localSubscribed ? "Subscribed locally — no server sync" : "Add to Library…",
                          systemImage: localSubscribed ? "checkmark.circle" : "plus.circle")
                        .font(.subheadline)
                }
                .disabled(localSubscribed)
                .accessibilityIdentifier("librivox-import-menu")
            }
        }
    }

    private func startServerImport() {
        // Wi-Fi gate (books run 100-500 MB). The existing cellular warning
        // mechanism; explicit confirmation continues on cellular.
        let warn = AppStorageKeys.warnCellularDownloadValue
        Task {
            if warn, !(await NetworkStatus.isOnWiFi()) {
                showWiFiWarning = true
            } else {
                await pickLibraryAndStart()
            }
        }
    }

    private func pickLibraryAndStart() async {
        // Remembered target; picker on first use (or when it vanished).
        let storedLib = AppStorageKeys.string(AppStorageKeys.librivoxImportLibraryId)
        if let storedLib, absLibraries.contains(where: { $0.id == storedLib }),
           let folder = AppStorageKeys.string(AppStorageKeys.librivoxImportFolderId) {
            begin(libraryId: storedLib, folderId: folder)
        } else {
            showLibraryPicker = true
        }
    }

    private func begin(libraryId: String, folderId: String) {
        guard let book else { return }
        LibriVoxImporter.shared.start(book: book, itemId: item.id,
                                      libraryId: libraryId, folderId: folderId)
    }

    private func subscribeLocally() {
        guard let rss = book?.url_rss, !rss.isEmpty else { return }
        Task {
            localSubscribed = await PodcastSubscriptions.shared.subscribe(urlString: rss)
        }
    }
}
