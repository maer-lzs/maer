// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The groups of one kind of the own library (authors, series, genres),
/// each with its count; a tap opens the books of that group
/// (`LibraryListRoute.books(of:named:)`). One page for the books tab and the
/// search deck. The grouping runs off the main thread, once per change of
/// the stock.
struct BookGroupsScreen: View {
    let kind: BookGroupKind
    let entries: [LibraryEntry]
    @State private var groups: [(name: String, count: Int)]?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let groups {
                    if groups.isEmpty {
                        Text("No results.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else {
                        ForEach(groups, id: \.name) { group in
                            NavigationLink(value: LibraryListRoute.books(of: kind, named: group.name)) {
                                DeckEntryRowLabel(title: group.name, count: group.count)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .bottomBarClearance()
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: ContentToken.of(entries.map(\.id))) {
            groups = await LibraryViewModel.groupsOffMain(kind, of: entries)
        }
    }
}
