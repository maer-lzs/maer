// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// What a link on maer.fm opens in the app. The link opens only what
/// `SharedLink.offers` confirms with the same question as sharing, so a link
/// built by hand around a private feed or an address with access opens
/// nothing. The ways to the content are seams: whether an episode is known,
/// reading a feed nobody follows, resolving a catalog book.
struct SharedLinkOpener {
    /// What the app opens for a link.
    enum Outcome: Equatable {
        case episode(itemId: String)
        case show(feedURL: String)
        case station(RadioStation)
        case book(itemId: String)
        /// Not a link of this form, or one the app does not open; the one
        /// sentence says so, the reason goes to the log.
        case refused(reason: String)
    }

    /// The question of the export: whether a feed address stays home.
    var staysHome: (String) -> Bool
    /// Whether the app resolves an episode id now.
    var knows: (String) -> Bool
    /// Reads a feed nobody follows and keeps its episodes for the visit;
    /// false when it could not be read.
    var browse: (String) async -> Bool
    /// Resolves a catalog title; false when it cannot be found.
    var resolveBook: (String) async -> Bool

    /// The one sentence for every link that opens nothing; a link does not
    /// tell whether it named something private.
    static let refusal = String(localized: "This link can't be opened.")

    /// The opener of the app: a feed nobody follows is read as the show
    /// page reads it, a catalog book is resolved by the session.
    static func live(knows: @escaping (String) -> Bool) -> SharedLinkOpener {
        SharedLinkOpener(
            staysHome: { PodcastSubscriptions.staysHome($0) },
            knows: knows,
            browse: { feedURL in
                guard let address = PodcastFeedAddress.requestURL(feedURL),
                      let show = await PodcastSubscriptions.fetchAndParse(feedURL: address) else { return false }
                BrowsedEpisodes.shared.remember(show: show)
                return true
            },
            resolveBook: { await AppSession.shared.resolveItem(forId: $0) != nil })
    }

    /// Opens what the link names through the one navigation point, or hands
    /// the one sentence to `refuse` and writes the reason to the log.
    func open(_ url: URL, refuse: (String) -> Void) async {
        let target: PlayerSourceTarget
        switch await outcome(for: url) {
        case .episode(let itemId): target = .podcastEpisode(itemId: itemId)
        case .show(let feedURL): target = .podcastShow(feedURL: feedURL)
        case .station(let station): target = .radioStation(station)
        case .book(let itemId): target = .catalogBook(itemId: itemId)
        case .refused(let reason):
            Logger.library.notice("SHAREDLINK refused reason=\(reason, privacy: .public)")
            refuse(Self.refusal)
            return
        }
        PlayerSourceRouter.shared.open(target)
    }

    func outcome(for url: URL) async -> Outcome {
        guard let content = SharedLink.read(url) else { return .refused(reason: "form") }
        guard SharedLink.offers(content, staysHome: staysHome) else { return .refused(reason: "notShared") }
        switch content {
        case .episode(let feedURL, let guid, _):
            let itemId = SharedLink.episodeId(feedURL: feedURL, guid: guid)
            if knows(itemId) { return .episode(itemId: itemId) }
            // A feed nobody follows: read it, then the episode resolves. An
            // episode that left the feed opens its show.
            guard await browse(feedURL) else { return .show(feedURL: feedURL) }
            return knows(itemId) ? .episode(itemId: itemId) : .show(feedURL: feedURL)
        case .show(let feedURL, _):
            return .show(feedURL: feedURL)
        case .station(let uuid, let facts):
            // The station plays from the stream the link names; the app
            // writes it with every station it shares.
            guard let stream = facts.audioURL else { return .refused(reason: "stationWithoutStream") }
            return .station(RadioStation(id: SharedLink.stationId(uuid: uuid), name: facts.title ?? "",
                                         streamURL: stream))
        case .book(let itemId, _):
            return await resolveBook(itemId) ? .book(itemId: itemId) : .refused(reason: "bookUnknown")
        }
    }
}
