// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// M4: lyrics panel in the player — synced lyrics get a live highlight that
/// follows playback (auto-scrolling) and tap-to-seek; unsynced lyrics render
/// as static text.
struct LyricsPanel: View {
    let lyrics: SongLyrics
    /// Absolute start of the current song within the album item — line
    /// timestamps are relative to the song.
    let songStart: Double
    @ObservedObject var viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    /// Index of the line currently being sung (synced only).
    private var activeIndex: Int? {
        guard lyrics.synced else { return nil }
        let now = viewModel.currentTime - songStart
        var active: Int?
        for (index, line) in lyrics.lines.enumerated() {
            guard let start = line.start else { continue }
            if start <= now { active = index } else { break }
        }
        return active
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                            Text(line.text)
                                .font(.title3.weight(index == activeIndex ? .bold : .regular))
                                .foregroundStyle(index == activeIndex ? .primary : .secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .id(index)
                                .onTapGesture {
                                    guard lyrics.synced, let start = line.start else { return }
                                    Task { await viewModel.seek(to: songStart + start) }
                                }
                        }
                    }
                    .padding()
                }
                .onChange(of: activeIndex) { _, index in
                    guard let index else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }
            .navigationTitle("Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
