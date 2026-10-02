// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The server guides as one list, in every state: a connected server keeps
/// its guide, for when something changes later. On the first level of the
/// setup and of the next steps it names every server once; on an area's
/// page, that area's servers.
struct ServerGuidesSection: View {
    /// The area whose servers to list; nil lists every server once.
    var area: SourceMapArea?

    var body: some View {
        let guides = ServerGuides.listed(in: area)
        if !guides.isEmpty {
            Section {
                ForEach(guides) { guide in
                    NavigationLink {
                        ServerGuidePage(guide: guide)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: guide.name)
                            Text(LocalizedStringKey(guide.oneLiner))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("server-guide-\(guide.id)")
                }
            } header: {
                Text("Set up a server")
            } footer: {
                Text("What each server does, what it needs and what you enter in Mär, with links to its documentation and source code.")
            }
        }
    }
}

/// One server: what it does, what it needs, what one enters in Mär, and
/// its documentation and source code, which open in the browser.
struct ServerGuidePage: View {
    let guide: ServerGuide

    var body: some View {
        Form {
            Section {
                Text(LocalizedStringKey(guide.oneLiner))
            } header: {
                Text("What it does")
            }
            Section {
                Text(LocalizedStringKey(ServerGuides.needs))
            } header: {
                Text("What you need")
            }
            Section {
                Text(LocalizedStringKey(guide.signIn.sentence))
            } header: {
                Text("What you enter in Mär")
            }
            Section {
                if let url = guide.docsURL {
                    link("Documentation", to: url, id: "docs")
                }
                if let url = guide.repoURL {
                    link("Source code", to: url, id: "repo")
                }
            } footer: {
                Text("They open in the browser.")
            }
        }
        .navigationTitle(Text(verbatim: guide.name))
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
    }

    private func link(_ title: LocalizedStringKey, to url: URL, id: String) -> some View {
        Link(destination: url) {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityIdentifier("server-guide-\(guide.id)-\(id)")
    }
}
