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
                 text: Text("\(collection) is indexed once on Wi-Fi. Only the directory, not the recordings."))
        case .loading(let done, let total):
            // It says INDEXING, because a directory is what is fetched: a
            // title list of a few megabytes, never the recordings. Someone
            // reading "loading 53,000 books" expects something else entirely.
            //
            // And it only names a number once one exists. A standing
            // "0 entries" while rows appear is worse than saying nothing
            // about the count.
            line(icon: "arrow.down.circle",
                 text: total > done && done > 0
                    ? Text("Indexing \(collection): \(done) of \(total) entries")
                    : (done > 0
                        ? Text("Indexing \(collection): \(done) entries")
                        : Text("Indexing \(collection)…")))
        case .failed:
            // A sentence someone can act on, and no code: the reason stands
            // in the log where it belongs.
            line(icon: "exclamationmark.triangle",
                 text: Text("\(collection) could not be indexed. It will be tried again."))
        }
    }

    private func line(icon: String, text: Text) -> some View {
        Label { text } icon: { Image(systemName: icon) }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
    }
}
