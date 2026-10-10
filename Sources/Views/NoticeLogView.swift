// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The log of every playback notice, newest first: what was said, about
/// which title, when. Reached from the pill and from the settings.
struct NoticeLogView: View {
    @ObservedObject var notices: PlaybackNotices

    var body: some View {
        List {
            if notices.log.isEmpty {
                Text("No notices yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(notices.log.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(entry.label, systemImage: entry.icon)
                        Text(Self.subtitle(entry))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationTitle("Notices")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The title, if one was playing, and the moment.
    private static func subtitle(_ entry: NoticeLogEntry) -> String {
        let when = Date(timeIntervalSince1970: entry.at).formatted(date: .abbreviated, time: .shortened)
        guard let title = entry.title, !title.isEmpty else { return when }
        return "\(title) · \(when)"
    }
}
