// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Which library of a source feeds which tab. Shown only when a source is set
/// to serve SEVERAL types, because only then is there anything to separate.
///
/// The whole section says what is missing: a mode the user switched on but that
/// cannot deliver yet is stated here, in the place where it can be fixed, and
/// it never becomes an empty tab. The three things it can say are three
/// different situations, not three phrasings of one: the list is not in yet ·
/// the server cannot separate what was asked for · you still have to choose.
struct SourceLibraryAssignmentSection: View {
    let modes: SourceModes
    let libraries: [SourceLibrary]
    @Binding var assignment: SourceLibraryAssignment
    /// Fetches the library list from the server. Nil while no client can be
    /// built (no address, no login). Then there is nothing to offer.
    let reload: (() async -> Void)?
    @State private var isLoading = false

    /// The unassigned choice. A raw value can never collide with it: every
    /// media type has a non-empty one.
    private static let unusedTag = ""

    private var separability: SourceLibraries.Separability {
        SourceLibraries.separability(modes: modes, known: libraries)
    }

    private var incomplete: [MediaType] {
        SourceLibraries.incompleteModes(modes: modes, known: libraries, assignment: assignment)
    }

    var body: some View {
        if modes.needsLibraryAssignment {
            Section {
                situation
                reloadButton
                warnings
            } header: {
                Text("Which library feeds which tab")
            } footer: {
                Text("A library feeds one tab. Anything left unused stays out of the app entirely.")
            }
        }
    }

    @ViewBuilder
    private var situation: some View {
        switch separability {
        case .notNeeded:
            EmptyView()
        case .unknown:
            note("Not loaded yet. Fetch this server's libraries to assign them.",
                 icon: "questionmark.folder", id: "subsonic-libraries-unknown")
        case .impossible(let count):
            // Not a defect and not a choice the user can make. The server
            // holds everything in one place, and one place cannot be two
            // things. Saying which way out exists beats an apology.
            note("This server reports only \(count) library. Mär cannot tell music from audiobooks inside one library. Turn one mode off, or separate them on the server.",
                 icon: "exclamationmark.triangle", id: "subsonic-libraries-impossible")
        case .possible:
            ForEach(libraries) { library in
                picker(for: library)
            }
        }
    }

    private func picker(for library: SourceLibrary) -> some View {
        Picker(selection: binding(for: library.id)) {
            Text("Not used").tag(Self.unusedTag)
            ForEach(modes.types) { type in
                Text(type.label).tag(type.rawValue)
            }
        } label: {
            Text(verbatim: library.name)
        }
        .accessibilityIdentifier("subsonic-library-\(library.id)")
    }

    @ViewBuilder
    private var reloadButton: some View {
        if let reload {
            Button {
                isLoading = true
                Task { await reload(); isLoading = false }
            } label: {
                Label("Reload libraries", systemImage: "arrow.clockwise")
            }
            .disabled(isLoading)
            .accessibilityIdentifier("subsonic-libraries-reload")
        }
        if isLoading {
            HStack { ProgressView(); Text("Working…").foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder
    private var warnings: some View {
        ForEach(incomplete, id: \.self) { type in
            note("\(type.label) has no library yet. That tab stays off until you pick one.",
                 icon: "exclamationmark.triangle",
                 id: "subsonic-mode-incomplete-\(type.rawValue)")
        }
    }

    private func note(_ text: LocalizedStringKey, icon: String, id: String) -> some View {
        Label(text, systemImage: icon)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(id)
    }

    /// One library, one type: a library can never hold two answers at once.
    private func binding(for libraryId: String) -> Binding<String> {
        Binding(
            get: { assignment[libraryId]?.rawValue ?? Self.unusedTag },
            set: { assignment[libraryId] = MediaType(rawValue: $0) }
        )
    }
}
