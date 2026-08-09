// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// c125ccd: the CHANNEL artwork of a podcast feed, read from the feed's
/// HEAD — curated entries (and directory hits without artwork) carry no
/// image URL of their own, but every feed states one. Pure pieces here; the
/// network actor does the ranged fetch and the caching.
///
/// The channel image sits before the first `<item>`; an episode image after
/// it must never win (the first episode's cover would masquerade as the
/// show's). Both spellings occur: `<itunes:image href="…">` and the RSS
/// `<image><url>…</url></image>`.
nonisolated enum FeedArtworkLookup {
    /// How much of the feed the resolver reads — measured on the curated
    /// public-broadcast feeds (WDR/BR/hr2/Ö1): all four state the channel
    /// image well within this, and a partial read is exactly the point.
    static let headByteCount = 16_384

    static func channelImageURL(fromHead head: String) -> URL? {
        // Everything after the first item belongs to an EPISODE.
        let channel: Substring
        if let firstItem = head.range(of: "<item", options: .caseInsensitive) {
            channel = head[..<firstItem.lowerBound]
        } else {
            channel = head[...]
        }
        if let href = itunesImageHref(in: channel) { return url(href) }
        if let rss = rssImageURL(in: channel) { return url(rss) }
        return nil
    }

    /// `<itunes:image href="…"/>` — attribute order and quoting vary, so the
    /// tag is located first and the href read inside it.
    private static func itunesImageHref(in channel: Substring) -> String? {
        guard let tag = channel.range(of: "<itunes:image", options: .caseInsensitive),
              let end = channel.range(of: ">", range: tag.upperBound..<channel.endIndex)
        else { return nil }
        let body = channel[tag.upperBound..<end.lowerBound]
        guard let hrefKey = body.range(of: "href", options: .caseInsensitive),
              let quote = body[hrefKey.upperBound...].first(where: { $0 == "\"" || $0 == "'" }),
              let open = body[hrefKey.upperBound...].firstIndex(of: quote)
        else { return nil }
        let after = body[body.index(after: open)...]
        guard let close = after.firstIndex(of: quote) else { return nil }
        return String(after[..<close])
    }

    /// The plain RSS `<image><url>…</url></image>` on channel level.
    private static func rssImageURL(in channel: Substring) -> String? {
        guard let image = channel.range(of: "<image", options: .caseInsensitive),
              let urlOpen = channel.range(of: "<url>", options: .caseInsensitive,
                                          range: image.upperBound..<channel.endIndex),
              let urlClose = channel.range(of: "</url>", options: .caseInsensitive,
                                           range: urlOpen.upperBound..<channel.endIndex)
        else { return nil }
        return String(channel[urlOpen.upperBound..<urlClose.lowerBound])
    }

    private static func url(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Feeds hand out escaped ampersands inside attributes.
            .replacingOccurrences(of: "&amp;", with: "&")
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }
}
