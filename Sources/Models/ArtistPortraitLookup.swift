// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

// Wire subsets for the artist-portrait chain (MusicBrainz → Wikidata →
// Wikimedia Commons). Foundation-only (MaerCore rule) — the orchestration
// lives in `ArtistPortraitService`.

nonisolated struct MBArtistResponse: Decodable, Sendable {
    let relations: [MBRelation]?
}
nonisolated struct MBRelation: Decodable, Sendable {
    let type: String?
    let url: MBRelationURL?
}
nonisolated struct MBRelationURL: Decodable, Sendable {
    let resource: String?
}
nonisolated struct MBArtistSearchResponse: Decodable, Sendable {
    let artists: [MBArtistHit]?
}
nonisolated struct MBArtistHit: Decodable, Sendable {
    let id: String
    let name: String?
    let score: Int?
}

/// Pure (tested): URL building + parsing for the no-key portrait chain —
/// server first (caller's job), then MusicBrainz artist (by MBID, else a
/// CONSERVATIVE name search), its Wikidata relation, Wikidata P18, a Commons
/// thumbnail. Same open-sources principle as Lyrics/LRCLIB and CAA.
nonisolated enum ArtistPortraitLookup {
    /// MB artist lookup by MBID, with URL relations (carries the Wikidata link).
    static func artistByMBIDURL(_ mbid: String) -> URL? {
        guard !mbid.isEmpty else { return nil }
        return URL(string: "https://musicbrainz.org/ws/2/artist/\(mbid)?inc=url-rels&fmt=json")
    }

    /// MB artist SEARCH by name — used only without an MBID; the caller
    /// accepts the hit only when `uniqueSearchHit` says it is unambiguous.
    static func artistSearchURL(name: String) -> URL? {
        let n = RadioArtworkLookup.escapeLucene(name)
        guard !n.isEmpty,
              var comps = URLComponents(string: "https://musicbrainz.org/ws/2/artist") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "query", value: "artist:\"\(n)\""),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "2"),
        ]
        return comps.url
    }

    /// Conservative: exactly one strong hit (score ≥ 95) whose name matches
    /// case-insensitively — a color circle beats a WRONG face.
    static func uniqueSearchHit(_ response: MBArtistSearchResponse, name: String) -> String? {
        let strong = (response.artists ?? []).filter { ($0.score ?? 0) >= 95 }
        guard strong.count == 1, let hit = strong.first,
              hit.name?.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        else { return nil }
        return hit.id
    }

    /// The artist's Wikidata entity id (Q…) from its MB URL relations.
    static func wikidataEntity(_ response: MBArtistResponse) -> String? {
        for relation in response.relations ?? [] where relation.type == "wikidata" {
            if let resource = relation.url?.resource,
               let q = resource.split(separator: "/").last, q.hasPrefix("Q") {
                return String(q)
            }
        }
        return nil
    }

    static func wikidataEntityURL(_ entity: String) -> URL? {
        guard entity.hasPrefix("Q") else { return nil }
        return URL(string: "https://www.wikidata.org/wiki/Special:EntityData/\(entity).json")
    }

    /// P18 (image) claim → the Commons file name, from the raw EntityData JSON
    /// (parsed structurally — the shape is deep but stable).
    static func p18FileName(fromEntityData data: Data, entity: String) -> String? {
        claimFileName(fromEntityData: data, entity: entity, property: "P18")
    }

    /// Generalized claim-image extraction (P18 portraits, P154 logos) — the
    /// radio logo chain reuses the SAME parser.
    static func claimFileName(fromEntityData data: Data, entity: String, property: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entities = root["entities"] as? [String: Any],
              let ent = entities[entity] as? [String: Any],
              let claims = ent["claims"] as? [String: Any],
              let claim = claims[property] as? [[String: Any]],
              let mainsnak = claim.first?["mainsnak"] as? [String: Any],
              let datavalue = mainsnak["datavalue"] as? [String: Any],
              let value = datavalue["value"] as? String, !value.isEmpty else { return nil }
        return value
    }

    /// Commons serves a sized thumbnail via Special:FilePath.
    static func commonsThumbURL(fileName: String, width: Int = 400) -> URL? {
        guard !fileName.isEmpty,
              var comps = URLComponents(string: "https://commons.wikimedia.org/wiki/Special:FilePath/\(fileName)") else { return nil }
        comps.queryItems = [URLQueryItem(name: "width", value: String(width))]
        return comps.url
    }
}
