// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

struct ChapterListView: View {
    let chapters: [ABSChapter]
    let currentChapter: ABSChapter?
    /// S19b: the list is a track/rest fallback (server chapters didn't cover the
    /// book) — show a discreet hint.
    var isFallback = false
    /// X23: music titles the sheet "Tracks" (the list is the album's tracks).
    var isMusic = false
    let onSelect: (ABSChapter) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            // S12: books/albums can have 150+ chapters/tracks — open straight on
            // the playing one and highlight it, instead of scrolled to the top.
            ScrollViewReader { proxy in
                List {
                    if isFallback {
                        Text("Chapters incomplete — track navigation")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(chapters) { chapter in
                        let isActive = chapter.id == currentChapter?.id
                        Button {
                            onSelect(chapter)
                        } label: {
                            HStack {
                                Text(chapter.title)
                                    .fontWeight(isActive ? .semibold : .regular)
                                    .foregroundStyle(isActive ? AnyShapeStyle(AppTheme.accent) : AnyShapeStyle(.primary))
                                Spacer()
                                if isActive {
                                    Image(systemName: "waveform")
                                        .foregroundStyle(AppTheme.accent)
                                }
                            }
                        }
                        .listRowBackground(isActive ? AppTheme.accent.opacity(0.12) : nil)
                        .id(chapter.id)
                    }
                }
                // X23: shared selector label — "Tracks" for music, "Parts" for
                // a fallback book, "Chapters" only for real chapters.
                .navigationTitle(ChapterModel.selectorLabel(isMusic: isMusic, isFallback: isFallback))
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .onAppear {
                    guard let id = currentChapter?.id else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }
}
