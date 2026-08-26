// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The IN-FEED signal for "do not list this publicly" — the
/// de-facto standard hosters set on private/premium feeds (Captivate,
/// Megaphone, Acast document it as a required step), plus its Podcasting-2.0
/// successor. Reading it replaces hand-marking for the whole class of
/// personalised feeds whose token rides in the PATH, which the query-param
/// heuristic cannot see at all.
///
/// Semantics, honestly: block means "not publicly listed" — a FREE unlisted
/// feed carries it too. That is fine for our protective behaviour (an
/// intentionally unlisted feed does not belong in an export or a sync either),
/// which is why the class capsule says "Private", not "Premium".
nonisolated enum PodcastFeedBlock {
    /// Channel-level `<itunes:block>yes</itunes:block>` or
    /// `<podcast:block value="yes">` WITHOUT a platform slug (unbounded yes
    /// = nobody may list it). An episode-level block means something else
    /// entirely and is ignored — only the head before the first `<item>`
    /// counts.
    static func isBlocked(feedHead head: String) -> Bool {
        let channel: Substring
        if let firstItem = head.range(of: "<item", options: .caseInsensitive) {
            channel = head[..<firstItem.lowerBound]
        } else {
            channel = head[...]
        }
        if elementSaysYes(in: channel, tag: "itunes:block") { return true }
        return podcastBlockSaysYes(in: channel)
    }

    /// `<itunes:block>Yes</itunes:block>` — case-tolerant, whitespace-tolerant.
    private static func elementSaysYes(in channel: Substring, tag: String) -> Bool {
        var searchStart = channel.startIndex
        while let open = channel.range(of: "<\(tag)", options: .caseInsensitive,
                                       range: searchStart..<channel.endIndex) {
            guard let tagEnd = channel.range(of: ">", range: open.upperBound..<channel.endIndex)
            else { return false }
            searchStart = tagEnd.upperBound
            guard let close = channel.range(of: "</\(tag)>", options: .caseInsensitive,
                                            range: tagEnd.upperBound..<channel.endIndex)
            else { continue }
            let value = channel[tagEnd.upperBound..<close.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if value == "yes" { return true }
        }
        return false
    }

    /// `<podcast:block value="yes"/>` — a `platform` attribute BOUNDS the
    /// block to one directory and says nothing about the feed being private,
    /// so only the unbounded form counts.
    private static func podcastBlockSaysYes(in channel: Substring) -> Bool {
        var searchStart = channel.startIndex
        while let open = channel.range(of: "<podcast:block", options: .caseInsensitive,
                                       range: searchStart..<channel.endIndex) {
            guard let tagEnd = channel.range(of: ">", range: open.upperBound..<channel.endIndex)
            else { return false }
            let body = channel[open.upperBound..<tagEnd.lowerBound]
            searchStart = tagEnd.upperBound
            if body.range(of: "platform", options: .caseInsensitive) != nil { continue }
            if attribute("value", in: body)?.lowercased() == "yes" { return true }
            // The element form `<podcast:block>yes</podcast:block>` occurs too.
            if elementSaysYes(in: channel[open.lowerBound...], tag: "podcast:block") { return true }
        }
        return false
    }

    private static func attribute(_ name: String, in body: Substring) -> String? {
        guard let key = body.range(of: name, options: .caseInsensitive),
              let quote = body[key.upperBound...].first(where: { $0 == "\"" || $0 == "'" }),
              let open = body[key.upperBound...].firstIndex(of: quote)
        else { return nil }
        let after = body[body.index(after: open)...]
        guard let close = after.firstIndex(of: quote) else { return nil }
        return String(after[..<close]).trimmingCharacters(in: .whitespaces)
    }
}
