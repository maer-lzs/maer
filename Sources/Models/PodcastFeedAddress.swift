// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The address a feed request actually goes to. One rule, one place.
///
/// App Transport Security allows cleartext for MEDIA only (a deliberate
/// decision for radio streams); every `URLSession` call needs https. Podcast
/// directories still hand out `http://` addresses for feeds that answer
/// identically over https, so an unchanged request made a LIVING feed look
/// dead: the fetch never left the device, and the surface reported "could not
/// be loaded".
///
/// There is deliberately NO fallback to http when https fails. Under ATS
/// cleartext can never succeed, so a fallback would only trade a clear failure
/// for a confusing one.
nonisolated enum PodcastFeedAddress {

    /// The URL to request for a stored or directory-supplied feed address.
    /// Scheme-less input is assumed to be https (the same assumption the
    /// subscribe path always made); `http://` is raised to https.
    static func requestURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let scheme = URL(string: trimmed)?.scheme?.lowercased(),
           scheme != "http", scheme != "https" {
            // Something that is not web transport at all (file:, itpc:, …).
            // Handing it to URLSession is not this rule's business.
            return URL(string: trimmed)
        }
        return URL(string: upgradedString(trimmed))
    }

    /// The same rule for an address that is already a `URL`. The funnel every
    /// feed fetch passes through, so a call site that builds its URL itself
    /// cannot sneak cleartext past the rule.
    static func upgraded(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http" else { return url }
        return URL(string: upgradedString(url.absoluteString)) ?? url
    }

    private static func upgradedString(_ address: String) -> String {
        let lowered = address.lowercased()
        if lowered.hasPrefix("http://") {
            return "https://" + address.dropFirst("http://".count)
        }
        if lowered.hasPrefix("https://") { return address }
        return "https://" + address
    }
}
