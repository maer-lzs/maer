// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import UIKit

/// What a page shares: the link on maer.fm and the picture of its preview.
struct SharedLinkOffer {
    let url: URL
    let preview: Image
}

/// The share entry of a page's actions: a link on maer.fm for a public
/// episode, show, station, catalog book or Jamendo track, with the cover as
/// its preview.
struct SharedLinkButton: View {
    let offer: SharedLinkOffer
    let title: String?

    var body: some View {
        let subject = title ?? "Mär"
        ShareLink(item: offer.url, subject: Text(verbatim: subject),
                  preview: SharePreview(subject, image: offer.preview)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("share-link")
    }
}

/// The picture of the preview: the cover the app already keeps, read from
/// memory or disk and never from the network; without one, the app's icon.
enum SharedLinkPreview {
    static func image(cover: URL?,
                      stored: (URL) async -> UIImage? = { await Artwork.thumbnail(for: $0) }) async -> Image {
        if let cover, let picture = await stored(cover) { return Image(uiImage: picture) }
        return appIcon.map { Image(uiImage: $0) } ?? Image(systemName: "waveform")
    }

    /// The app's own icon, by the last file name its bundle lists.
    static var appIcon: UIImage? {
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        guard let name = (primary?["CFBundleIconFiles"] as? [String])?.last else { return nil }
        return UIImage(named: name)
    }
}

extension View {
    /// Asks `SharedLink.shareURL` for the page's content with its cover
    /// (`SharedLink.withCover`) once per content and keeps the offer in
    /// `offer`, with the cover from the app's store as the preview; nil
    /// leaves the page without a share entry. The question whether a feed
    /// stays home reads settings and the keychain, so it is not asked at
    /// every drawing.
    func sharedLink(_ content: SharedLink.Content?, cover: URL?, to offer: Binding<SharedLinkOffer?>) -> some View {
        let shared = SharedLink.withCover(content, cover: cover?.absoluteString)
        return task(id: shared) {
            guard let url = SharedLink.shareURL(shared, staysHome: { PodcastSubscriptions.staysHome($0) }) else {
                offer.wrappedValue = nil
                return
            }
            offer.wrappedValue = SharedLinkOffer(url: url, preview: await SharedLinkPreview.image(cover: cover))
        }
    }
}
