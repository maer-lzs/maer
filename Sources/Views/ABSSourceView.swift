// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Etappe E: Audiobookshelf as ONE source page like every other service.
/// The shared source pattern: access (connect/log out), per-source sync
/// button, source-specific extras (library picker). Reached from the
/// tab-independent source map (Areas → Audiobooks); the old per-tab Server/Sync scatter is
/// gone.
struct ABSSourceView: View {
    @ObservedObject private var authViewModel = AppSession.shared.authViewModel
    @ObservedObject var coordinator: PlayerCoordinator
    var libraryViewModel: LibraryViewModel?
    let onLogout: () -> Void

    @State private var showABSSetup = false
    @State private var showLogoutConfirm = false
    @State private var pendingSyncCount = 0
    @State private var isSyncing = false
    @State private var availableLibraries: [ABSLibrary] = []
    @State private var librariesFailed = false
    @AppStorage(AppStorageKeys.selectedLibraryId) private var selectedLibraryId = ""

    var body: some View {
        Form {
            Section {
                if authViewModel.isLoggedIn {
                    LabeledContent {
                        Text(authViewModel.serverAddress)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } label: {
                        Label("Address", systemImage: "server.rack")
                    }
                    Button(role: .destructive) {
                        showLogoutConfirm = true
                    } label: {
                        Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } else {
                    // Serverless mode. Audiobookshelf attaches HERE.
                    Button {
                        showABSSetup = true
                    } label: {
                        Label("Connect to Audiobookshelf", systemImage: "server.rack")
                    }
                }
            } header: {
                Text("Server")
            }

            if authViewModel.isLoggedIn {
                // The ONE per-source sync pattern (like music/gpodder): a
                // visible button + what is still pending.
                Section {
                    LabeledContent {
                        Text("\(pendingSyncCount)")
                    } label: {
                        Label("Pending Updates", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button {
                        isSyncing = true
                        Task {
                            await SyncQueue.shared.flush(targetFor: AppSession.shared.progressTarget)
                            pendingSyncCount = SyncQueue.shared.allPending().count
                            isSyncing = false
                        }
                    } label: {
                        if isSyncing {
                            ProgressView()
                        } else {
                            Label("Sync Now", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(pendingSyncCount == 0 || isSyncing)
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Progress updates that could not reach the server yet are sent automatically as soon as possible.")
                }

                if availableLibraries.count > 1 {
                    Section("Library") {
                        Picker(selection: $selectedLibraryId) {
                            ForEach(availableLibraries) { library in
                                Text(library.name).tag(library.id)
                            }
                        } label: {
                            Label("Library", systemImage: "books.vertical")
                        }
                        .onChange(of: selectedLibraryId) { _, _ in
                            Task { await libraryViewModel?.loadLibrary() }
                        }
                    }
                } else if librariesFailed {
                    // The list could not be read: not "one library".
                    Section("Library") {
                        LoadFailedView(form: .row) { Task { await loadLibraries() } }
                    }
                }
            }
        }
        .navigationTitle("Audiobookshelf")
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
        .task {
            pendingSyncCount = SyncQueue.shared.allPending().count
            await loadLibraries()
        }
        .sheet(isPresented: $showABSSetup) {
            // The login form alone. Presenting the whole first screen here
            // would offer "start without a server" to someone who is already
            // in the app and looking for the opposite.
            NavigationStack { ABSLoginPage(viewModel: authViewModel) }
                .softTopScrollEdge()
                .followsAppearanceChoice()
        }
        .onChange(of: authViewModel.isLoggedIn) { _, loggedIn in
            if loggedIn { showABSSetup = false }
        }
        .confirmationDialog("Log out from the server?", isPresented: $showLogoutConfirm) {
            Button("Log Out", role: .destructive) { onLogout() }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// The server's book libraries for the picker. ONLY book libraries:
    /// podcast libraries belong to the podcast source. A failure says so in
    /// the library section with a retry and keeps the choice made.
    private func loadLibraries() async {
        guard authViewModel.isLoggedIn else { return }
        let provider = coordinator.provider
        switch await FetchAnswer.of("abs libraries", logger: .library, { try await provider.fetchLibraries() }) {
        case .value(let libraries):
            availableLibraries = libraries.filter { !$0.isPodcast }
            librariesFailed = false
            if selectedLibraryId.isEmpty || !availableLibraries.contains(where: { $0.id == selectedLibraryId }) {
                selectedLibraryId = availableLibraries.first?.id ?? ""
            }
        case .failed:
            librariesFailed = availableLibraries.isEmpty
        case .cancelled:
            break
        }
    }
}
