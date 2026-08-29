// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// What the first fetch of a collection looks like FOR THE USER.
///
/// It is a surface, not a log line: the fetch runs once per collection and
/// takes measurable time, so it says that it runs, how far it is, and what
/// stands in its way. The surface itself keeps working meanwhile through the
/// day store, so this never blocks anything.
///
/// ONE component for every catalogue surface. A second wording would drift,
/// and the sentence is the same everywhere.
struct CatalogStockNotice: View {
    let state: CatalogStockService.State
    /// The collection in the user's words, for the sentence.
    let collection: String

    var body: some View {
        switch state {
        case .idle, .ready:
            // Nothing to say. A stock that is there is not news.
            EmptyView()
        case .waitingForWiFi:
            line(icon: "wifi.slash",
                 text: Text("\(collection) is loaded once on Wi-Fi. It is not fetched over cellular."))
        case .loading(let done, let total):
            // The truth about the progress: the number that is IN, and the
            // total only once the source has stated it.
            line(icon: "arrow.down.circle",
                 text: total > done
                    ? Text("Loading \(collection): \(done) of \(total) entries")
                    : Text("Loading \(collection): \(done) entries"))
        case .failed(let reason):
            line(icon: "exclamationmark.triangle",
                 text: Text("\(collection) could not be loaded: \(reason)"))
        }
    }

    private func line(icon: String, text: Text) -> some View {
        Label { text } icon: { Image(systemName: icon) }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
    }
}
