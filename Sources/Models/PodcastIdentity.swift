// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The stable ids of the podcast stock and the merging of duplicates: the
/// feed key and its hash, the comparable form of a feed address, the masked
/// form for display and logs, and the migration that re-keys shows and
/// episodes and folds twins of one feed together. Pure, one implementation,
/// no seam: a witness calls the functions. What reads the settings (the
/// premium and block markings) stays with the subscriptions.
nonisolated enum PodcastIdentity {
    /// Deterministic key of a feed (an FNV-1a-shaped hash, hex, over the
    /// normalised URL). Replaces the previously used `String.hashValue`,
    /// which was re-seeded on each app start and thus caused duplicates and
    /// progress loss.
    nonisolated static func feedKey(_ feedURL: String) -> String {
        stableHash(normalizeFeedURL(feedURL))
    }

    /// A token address as a measuring line, never the token: the feed key
    /// (the same on every device), a hash of the address exactly as held or
    /// fetched, and whether it carries capitals. Two devices' lines with the
    /// same key and a different address hash hold different addresses.
    nonisolated static func addressLine(_ feedURL: String) -> String {
        let key = feedKey(feedURL).prefix(8)
        let address = stableHash(feedURL).prefix(8)
        let capitals = feedURL.contains { $0.isUppercase }
        return "key=\(key) addr=\(address) capitals=\(capitals)"
    }

    /// FNV-1a with the FNV prime, but NOT the FNV offset basis: the start
    /// value lacks the last digit of 14695981039346656037, so the result is
    /// not FNV-1a (the empty string gives 14650fb0739d0383, not
    /// cbf29ce484222325). It must never be "corrected": every feed key, show
    /// id and position key built from it would change, and every stored one
    /// would be orphaned. `PodcastSubscriptionsHashTests` holds two values.
    nonisolated static func stableHash(_ s: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 16)
    }

    /// Query parameters whose VALUES are access secrets. A feed carrying
    /// one is the token-URL premium class (access baked into the URL, no login).
    /// ONE source: the identity set below builds on this, no duplication.
    /// "freebie" joined after the ZEIT leak finding (their premium
    /// class uses `freebie=<token>`). ONE set feeds detection, masking AND
    /// the OPML-export guard.
    nonisolated static let secretQueryParams: Set<String> = PodcastFeedAddress.secretQueryParams

    /// Query parameters that carry feed IDENTITY. Two URLs differing in one of
    /// these are DIFFERENT feeds (private tokens, CMS show selectors) and must
    /// not collapse into one subscription. Everything else (tracking params
    /// etc.) is still stripped.
    nonisolated private static let identityQueryParams: Set<String> =
        secretQueryParams.union(["id", "show", "feed", "user", "podcast"])

    /// The show behind a statistics key. Episode ids are `rss:<feed key>:<guid>`
    /// and the statistics fold them to `rss:<feed key>`, while a show's own
    /// id is `feed:<feed key>`; the two never matched, so the statistics
    /// page showed keys instead of names.
    ///
    /// `heard` are the stocks that remember a show without following it
    /// (the listen log, the episodes kept from browsing): each entry carries
    /// its feed address and the show's name. A show listened to for hours
    /// and then unsubscribed, or only ever browsed, still has its name
    /// there.
    nonisolated static func showTitle(for showId: String, in shows: [PodcastShow],
                                      heard: [(feedURL: String, title: String)] = []) -> String? {
        if let direct = shows.first(where: { $0.id == showId }) { return direct.title }
        let parts = showId.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let key = String(parts[1])
        if let followed = shows.first(where: { $0.id == "feed:\(key)" || feedKey($0.feedURL) == key }) {
            return followed.title
        }
        return heard.first { !$0.title.isEmpty && feedKey($0.feedURL) == key }?.title
    }

    /// Provider-premium (Teil 5 cut): the comparable host of a feed URL.
    /// Scheme/`www.` stripped, lowercased, up to the first path segment.
    nonisolated static func feedHost(_ raw: String) -> String {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "https://", with: "")
             .replacingOccurrences(of: "http://", with: "")
        if s.hasPrefix("www.") { s.removeFirst(4) }
        if let slash = s.firstIndex(where: { $0 == "/" || $0 == "?" }) { s = String(s[..<slash]) }
        return s
    }

    /// Display/log-safe form. Secret parameter values become "••••",
    /// everything else stays. Never show/log a token feed URL unmasked.
    nonisolated static func maskedFeedURL(_ raw: String) -> String {
        guard let q = raw.firstIndex(of: "?") else { return raw }
        let base = raw[..<q]
        let masked = raw[raw.index(after: q)...].split(separator: "&").map { pair -> String in
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, secretQueryParams.contains(parts[0].lowercased()) else {
                return String(pair)
            }
            return "\(parts[0])=••••"
        }
        return base + "?" + masked.joined(separator: "&")
    }

    /// Make feed URLs comparable (scheme/`www.`/query/trailing slash ignored) so
    /// http/https or slash variants of the same feed collapse together.
    nonisolated static func normalizeFeedURL(_ raw: String) -> String {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var identityQuery = ""
        if let q = s.firstIndex(of: "?") {
            // Keep identity-relevant parameters (sorted, canonical) so feeds
            // that differ only in a token/show id stay distinct subscriptions;
            // drop the rest (tracking) as before.
            let query = String(s[s.index(after: q)...])
            let kept = query.split(separator: "&")
                .filter { pair in
                    let name = pair.split(separator: "=", maxSplits: 1)[0]
                    return identityQueryParams.contains(String(name))
                }
                .sorted()
            if !kept.isEmpty { identityQuery = "?" + kept.joined(separator: "&") }
            s = String(s[..<q])
        }
        s = s.replacingOccurrences(of: "https://", with: "")
             .replacingOccurrences(of: "http://", with: "")
        if s.hasPrefix("www.") { s.removeFirst(4) }
        while s.hasSuffix("/") { s.removeLast() }
        return s + identityQuery
    }

    /// Identity WITHOUT the secret VALUES. The ZEIT class rotates
    /// its `freebie` token, and since the token joined the identity params
    /// a rotated token spawned a TWIN of the same feed (the
    /// screenshot: two entries, identical masked URL). Same masked identity
    /// ⇒ same resource on one device.
    nonisolated static func collapseKey(_ feedURL: String) -> String {
        stableHash(maskedFeedURL(normalizeFeedURL(feedURL)))
    }

    /// Pure migration core (testable): re-key ids/guids, report every progress
    /// move via `moveProgress(old, new)`, dedupe shows of the same feed.
    /// Stage 1 on the exact identity, stage 2 on the MASKED
    /// identity so token rotations collapse too. The survivor of a stage-2
    /// collision is the entry with MORE episodes (the freshly parsed full
    /// feed carries the CURRENT token in its URL); the loser's episodes fold
    /// in re-keyed, progress rides along via `moveProgress`.
    ///
    /// `retired(loser, survivor)` names each token-rotation twin that was
    /// folded away, by feed URL, so the caller can say it to the account:
    /// otherwise the loser's statement with the OLD token keeps travelling,
    /// and a new device adopts an address that answers 403.
    nonisolated static func migrate(
        _ decoded: [PodcastShow],
        moveProgress: (String, String) -> Void,
        retired: (_ loser: String, _ survivor: String) -> Void = { _, _ in }
    ) -> (shows: [PodcastShow], changed: Bool) {
        var byKey: [String: PodcastShow] = [:]
        var order: [String] = []
        var changed = false

        for show in decoded {
            let key = feedKey(show.feedURL)
            var rebuilt = show
            rebuilt.id = "feed:\(key)"
            if rebuilt.id != show.id { changed = true }
            rebuilt.episodes = show.episodes.map { ep in
                var e = ep
                let newGuid = "rss:\(key):\(originalGuid(ep.guid))"
                if newGuid != ep.guid {
                    moveProgress(ep.guid, newGuid)
                    e.guid = newGuid
                    changed = true
                }
                return e
            }

            if let existing = byKey[key] {
                byKey[key] = merge(existing, rebuilt)
                changed = true
            } else {
                byKey[key] = rebuilt
                order.append(key)
            }
        }

        // Stage 2: collapse token-rotation twins (same MASKED id).
        var byMasked: [String: String] = [:]   // collapseKey → surviving exact key
        var removedKeys = Set<String>()
        for key in order {
            guard let show = byKey[key] else { continue }
            let masked = collapseKey(show.feedURL)
            guard let survivorKey = byMasked[masked] else {
                byMasked[masked] = key
                continue
            }
            guard var survivor = byKey[survivorKey], let loser = byKey[key] else { continue }
            // The fuller entry survives (its URL carries the current token).
            if loser.episodes.count > survivor.episodes.count {
                var newSurvivor = loser
                collapseInto(&newSurvivor, from: survivor, moveProgress: moveProgress)
                byKey[key] = newSurvivor
                byKey[survivorKey] = nil
                byMasked[masked] = key
                removedKeys.insert(survivorKey)
                retired(survivor.feedURL, newSurvivor.feedURL)
            } else {
                collapseInto(&survivor, from: loser, moveProgress: moveProgress)
                byKey[survivorKey] = survivor
                byKey[key] = nil
                removedKeys.insert(key)
                retired(loser.feedURL, survivor.feedURL)
            }
            changed = true
        }
        if !removedKeys.isEmpty {
            order.removeAll { removedKeys.contains($0) }
        }

        return (order.compactMap { byKey[$0] }, changed)
    }

    /// Fold `loser` into `survivor`: episodes match by ORIGINAL guid, get
    /// re-keyed to the survivor's feed key (progress rides along), unmatched
    /// old episodes join the union. Logged loudly with MASKED urls.
    private nonisolated static func collapseInto(
        _ survivor: inout PodcastShow, from loser: PodcastShow,
        moveProgress: (String, String) -> Void
    ) {
        let survivorKey = feedKey(survivor.feedURL)
        var rekeyed = loser
        rekeyed.episodes = loser.episodes.map { ep in
            var e = ep
            let newGuid = "rss:\(survivorKey):\(originalGuid(ep.guid))"
            if newGuid != ep.guid {
                moveProgress(ep.guid, newGuid)
                e.guid = newGuid
            }
            return e
        }
        // Argument order on purpose: the SECOND side wins the feed facts,
        // and that has to be the survivor here, because its URL carries the
        // current token. The store facts survive from either side (see
        // merge), so the loser only loses its outdated address.
        survivor = merge(rekeyed, survivor)
        let loserMasked = maskedFeedURL(loser.feedURL)
        let survivorMasked = maskedFeedURL(survivor.feedURL)
        Logger.rss.notice("PREMIUM identity merge: \(loserMasked, privacy: .public) folded into \(survivorMasked, privacy: .public)")
    }

    /// Extract the original guid from `rss:<hash>:<original>` (which may itself
    /// contain colons → maxSplits 2).
    nonisolated static func originalGuid(_ guid: String) -> String {
        let parts = guid.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        if parts.count == 3, parts[0] == "rss" { return String(parts[2]) }
        return guid
    }

    /// The same episode under another feed key: an id with the same
    /// original guid among the followed episodes, never the id itself.
    /// The guid is the episode's own name in its feed, so two feed keys
    /// for one show (a moved host, a premium twin) meet here.
    nonisolated static func twinEpisodeId(for id: String, among guids: [String]) -> String? {
        let wanted = originalGuid(id)
        guard wanted != id, !wanted.isEmpty else { return nil }
        return guids.first { $0 != id && originalGuid($0) == wanted }
    }

    /// Merge two versions of the same show: episodes as a union over `guid`,
    /// newest first. `internal` so the RSS hardening (never shrink on a thin
    /// fetch) can be driven from a unit test.
    ///
    /// **Classify fields instead of picking a side.**
    ///
    /// Picking the side with more episodes and then patching individual fields
    /// back requires someone to remember every field, every time. Two fields
    /// died that way before.
    ///
    /// The classification is objective, not a judgement call:
    ///  * **Feed facts** (title, image, description, categories, the
    ///    announced duration): a fresh parse knows them best, so the fresh
    ///    side wins.
    ///  * **Store facts** (`origin`, the measured asset length): a fresh
    ///    parse CANNOT know them at all. They survive from the stored side,
    ///    no matter which side has more episodes.
    ///
    /// The episode list stays a union over `guid`: a thin parse (valid title,
    /// few episodes) must never empty the cache. On a duplicate `guid` the
    /// classification applies at EPISODE level too, otherwise the same fact
    /// dies, only less visibly.
    ///
    /// The store facts are not taken blindly from `stored`. Whoever has them
    /// keeps them (`stored ?? fresh`). On a refresh that is the same thing,
    /// because a fresh parse never has them. But `collapseInto` uses this
    /// same merge to fold a twin entry into the survivor, and there the
    /// loser's origin must not be lost just because it is the second
    /// argument.
    nonisolated static func merge(_ stored: PodcastShow, _ fresh: PodcastShow) -> PodcastShow {
        var result = fresh
        result.origin = stored.origin ?? fresh.origin

        var storedByGuid: [String: PodcastEpisode] = [:]
        for episode in stored.episodes { storedByGuid[episode.guid] = episode }

        var seen = Set<String>()
        var episodes: [PodcastEpisode] = []
        for var episode in fresh.episodes where seen.insert(episode.guid).inserted {
            if let known = storedByGuid[episode.guid] { carryStoreFacts(from: known, into: &episode) }
            episodes.append(episode)
        }
        for episode in stored.episodes where seen.insert(episode.guid).inserted {
            episodes.append(episode)
        }
        result.episodes = episodes.sorted { $0.pubDate > $1.pubDate }
        return result
    }

    /// What only the store knows about an EPISODE. When this list grows, the
    /// shared cases in `Fixtures/Shared/abos/merge.json` (read by
    /// `PodcastMergeTests` and the Android side) have to grow with it. That
    /// is exactly what they are for.
    private nonisolated static func carryStoreFacts(from stored: PodcastEpisode,
                                                    into fresh: inout PodcastEpisode) {
        // Only when the other side carries no measurement of its own,
        // otherwise an older value would beat a newer one.
        if fresh.measuredDuration == nil, let measured = stored.measuredDuration, measured > 0 {
            fresh.measuredDuration = measured
            // Mirrored so every reader sees the best known length.
            fresh.duration = measured
        }
    }
}
