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
/// reading a feed nobody follows, resolving a catalog title. A link shows its
/// content and never starts playback.
struct SharedLinkOpener {
    /// What the app opens for a link.
    enum Outcome: Equatable {
        case episode(itemId: String)
        case show(feedURL: String)
        case station(RadioStation)
        case book(itemId: String)
        /// A free music track: the page of its release or of the track.
        case track(itemId: String)
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
    /// Resolves a catalog title, a book or a music track; false when it
    /// cannot be found.
    var resolveCatalog: (String) async -> Bool
    /// The catalog's own station for an id a link names; nil when it cannot
    /// be found. A link names a real station's id, so the name and the
    /// stream come from here, never from the link: a link built by hand
    /// would otherwise put a foreign stream under a real station, and it
    /// would travel with the recent stations and the choices.
    var resolveStation: (String) async -> RadioStation?

    /// The one sentence for every link that opens nothing; a link does not
    /// tell whether it named something private.
    static let refusal = String(localized: "This link can't be opened.")

    /// The opener of the app: a feed nobody follows is read as the show
    /// page reads it, a catalog title is resolved by the session (a Jamendo
    /// track nobody saw this session is asked for there).
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
            resolveCatalog: { await AppSession.shared.resolveItem(forId: $0) != nil },
            resolveStation: { uuid in
                do {
                    return try await RadioBrowserClient.station(uuid: uuid)
                } catch {
                    Logger.library.notice("SHAREDLINK station not resolved: \(FailureReason.of(error), privacy: .public)")
                    return nil
                }
            })
    }

    /// Opens what the link names through the one navigation point, or hands
    /// the one sentence to `refuse` and writes the reason to the log.
    func open(_ url: URL, refuse: (String) -> Void) async {
        let outcome = await outcome(for: url)
        guard let target = Self.target(of: outcome) else {
            if case .refused(let reason) = outcome {
                Logger.library.notice("SHAREDLINK refused reason=\(reason, privacy: .public)")
            }
            refuse(Self.refusal)
            return
        }
        PlayerSourceRouter.shared.open(target)
    }

    /// The page an outcome opens; nil for a refusal. A music track opens by
    /// the catalog's own rule: a song its release, a Jamendo track its page.
    static func target(of outcome: Outcome) -> PlayerSourceTarget? {
        switch outcome {
        case .episode(let itemId): .podcastEpisode(itemId: itemId)
        case .show(let feedURL): .podcastShow(feedURL: feedURL)
        case .station(let station): .radioStation(station)
        case .book(let itemId): .catalogBook(itemId: itemId)
        case .track(let itemId): PlayerSourceTargets.catalogPage(itemId, markedForm: nil)
        case .refused: nil
        }
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
        case .station(let uuid, _):
            // The link's own name and stream are for the page on maer.fm;
            // the app takes the station as the catalog has it.
            guard let station = await resolveStation(uuid),
                  station.id.lowercased() == SharedLink.stationId(uuid: uuid).lowercased()
            else { return .refused(reason: "stationUnknown") }
            return .station(station)
        case .book(let itemId, _):
            return await resolveCatalog(itemId) ? .book(itemId: itemId) : .refused(reason: "bookUnknown")
        case .track(let itemId, _):
            return await resolveCatalog(itemId) ? .track(itemId: itemId) : .refused(reason: "trackUnknown")
        }
    }
}
