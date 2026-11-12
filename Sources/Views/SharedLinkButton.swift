// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The share entry of a page's actions: a link on maer.fm for a public
/// episode, show, station or catalog book.
struct SharedLinkButton: View {
    let url: URL
    let title: String?

    var body: some View {
        let subject = title ?? "Mär"
        ShareLink(item: url, subject: Text(verbatim: subject), preview: SharePreview(subject)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("share-link")
    }
}

extension View {
    /// Asks `SharedLink.shareURL` for the page's content once per content
    /// and keeps the answer in `url`; nil leaves the page without a share
    /// entry. The question whether a feed stays home reads settings and the
    /// keychain, so it is not asked at every drawing.
    func sharedLink(_ content: SharedLink.Content?, to url: Binding<URL?>) -> some View {
        task(id: content) {
            url.wrappedValue = SharedLink.shareURL(content, staysHome: { PodcastSubscriptions.staysHome($0) })
        }
    }
}
