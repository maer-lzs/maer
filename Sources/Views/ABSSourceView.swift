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
                }
            }
        }
        .navigationTitle("Audiobookshelf")
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
        .task {
            pendingSyncCount = SyncQueue.shared.allPending().count
            if authViewModel.isLoggedIn,
               let libraries = try? await coordinator.provider.fetchLibraries() {
                // ONLY book libraries. Podcast libraries belong to the podcast
                // source, not the audiobook library picker.
                availableLibraries = libraries.filter { !$0.isPodcast }
                if selectedLibraryId.isEmpty || !availableLibraries.contains(where: { $0.id == selectedLibraryId }) {
                    selectedLibraryId = availableLibraries.first?.id ?? ""
                }
            }
        }
        .sheet(isPresented: $showABSSetup) {
            // The login form alone. Presenting the whole first screen here
            // would offer "start without a server" to someone who is already
            // in the app and looking for the opposite.
            NavigationStack { ABSLoginPage(viewModel: authViewModel) }
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
}
