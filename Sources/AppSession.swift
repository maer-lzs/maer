// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog

/// Process-wide playback/library session. Coordinator and LibraryViewModel used
/// to live as @StateObject in LibraryView. On a CarPlay COLD START (the app is
/// woken only for the car scene, no UI) they did not exist at all. Here they
/// belong to the process; UI and CarPlay scene share the same instances (one
/// player, one queue).
@MainActor
final class AppSession: ObservableObject {
    static let shared = AppSession()

    /// Source configuration as an OBSERVABLE state. Bumped whenever a
    /// source's availability may have changed (toggle, credential change,
    /// probe result). The tab bar derives `availableMediaTypes` from
    /// `isAvailable` on every render; without this signal nothing re-rendered
    /// after a settings change, so a toggled source only appeared/disappeared
    /// on the next incidental re-render (or app restart).
    @Published private(set) var sourcesVersion = 0

    func notifySourcesChanged() {
        // A provider's FIRST touch can happen inside a body render (the tab
        // bar reads `allProviders` while rendering) and its init calls
        // reloadConfig → here. Publishing during a view update is illegal.
        // Defer the bump out of the update cycle.
        Task { @MainActor in
            self.sourcesVersion += 1
        }
    }

    /// TF bib-toggles: apply a tab-master / source toggle change. Rebuilds the
    /// Subsonic client for its new active state (nil when off, so its calls
    /// stop) and refreshes the tab bar. Every library toggle in Settings calls
    /// this. The ONE entry point so a flipped toggle takes effect everywhere.
    func reconfigureSources() {
        SubsonicProvider.shared.reloadConfig()   // rebuilds/nils client + notifies
        JellyfinProvider.shared.reloadConfig()
        notifySourcesChanged()                   // toggles that don't touch the music clients
    }

    /// Owns the APIClient (built from the keychain). Base URL and token are
    /// updated IN PLACE on login, so the objects below stay valid.
    let authViewModel = AuthViewModel()

    /// The server provider (Audiobookshelf). Basis for login, library choice,
    /// settings. `apiClient` remains for the ABS-specific sign-in.
    var provider: any AudioProvider { authViewModel.apiClient }
    var apiClient: APIClient { authViewModel.apiClient }

    /// Local files as a second source (always present, no login).
    var localProvider: LocalProvider { LocalProvider.shared }

    /// Podcasts (RSS feeds) as a source of type `.podcasts`.
    var rssProvider: RSSProvider { RSSProvider.shared }

    /// Audiobookshelf podcasts (server-synced) as a second podcast source.
    var absPodcastProvider: ABSPodcastProvider { ABSPodcastProvider.shared }

    /// Subsonic/Navidrome music as a source of type `.music`.
    var subsonicProvider: SubsonicProvider { SubsonicProvider.shared }

    /// Jellyfin music as a second source of type `.music` (Etappe 2).
    var jellyfinProvider: JellyfinProvider { JellyfinProvider.shared }

    /// THE music access point for the UI: views and view models talk to this
    /// protocol, never to a concrete server type. With one active music
    /// source it is that source's provider; with BOTH it is `MusicUnion`,
    /// which asks both for every list and routes every id to its server.
    var musicProvider: any MusicProvider { musicProvider(serving: musicServing) }

    /// Which music servers serve music now. A Subsonic source can serve
    /// music, audiobooks or both; only the music half decides anything here.
    private var musicServing: MusicSourceRule.Serving {
        MusicSourceRule.serving(
            subsonicServesMusic: AppStorageKeys.subsonicActive(for: .music),
            jellyfinServesMusic: AppStorageKeys.jellyfinActive(for: .music))
    }

    /// The union of both music servers, one instance: its lists keep their
    /// paging state, and its signal relays both sources.
    private static let musicUnion = MusicUnion(sources: [SubsonicProvider.shared, JellyfinProvider.shared])

    /// The music servers that serve music now, Subsonic first.
    var activeMusicServers: [MusicSourceRule.Server] {
        MusicSourceRule.active(subsonicServesMusic: AppStorageKeys.subsonicActive(for: .music),
                               jellyfinServesMusic: AppStorageKeys.jellyfinActive(for: .music))
    }

    /// The source capsule of a music entry (F5b-4): its server's name while
    /// both music servers are active, nil with one. Every music surface
    /// asks here and hands the answer to the carrier it already has.
    func musicSourceLabel(forItemId itemId: String) -> String? {
        let source = musicProvider(for: itemId)
        guard let name = source.sourceNames[source.providerId] else { return nil }
        return MusicSourceName.capsule(serving: musicServing, name: name)
    }

    /// The provider for a serving answer. With ONE source it is exactly
    /// that source's provider, the object of before the union.
    func musicProvider(serving: MusicSourceRule.Serving) -> any MusicProvider {
        switch serving {
        case .one(let server): provider(of: server)
        case .both: Self.musicUnion
        }
    }

    /// The device's music server, by the one rule `MusicSourceRule`.
    private var deviceMusicServer: MusicSourceRule.Server {
        MusicSourceRule.device(subsonicServesMusic: AppStorageKeys.subsonicActive(for: .music),
                               jellyfinServesMusic: AppStorageKeys.jellyfinActive(for: .music))
    }

    private func provider(of server: MusicSourceRule.Server) -> any MusicProvider {
        switch server {
        case .subsonic: SubsonicProvider.shared
        case .jellyfin: JellyfinProvider.shared
        }
    }

    /// The music provider OF AN ITEM, not the configured one.
    ///
    /// `musicProvider` above answers „which music source does this device
    /// use", and with both servers active Subsonic wins for now. That is the
    /// right answer for a library listing and the wrong one for a title that
    /// carries its source in its id: the album page is reached from the full
    /// player as well, so a playing `jf:` album can open while the configured
    /// answer is Subsonic, and every question about that id then goes to a
    /// server that never heard of it.
    ///
    /// Same shape as `provider(for:)`, one level narrower.
    func musicProvider(for itemId: String) -> any MusicProvider {
        // No music namespace (a playlist id built here, a seeded item): the
        // configured source is the only sensible answer; the rule says so.
        provider(of: MusicSourceRule.item(itemId, device: deviceMusicServer))
    }

    /// Internet radio (Radio Browser catalog + manual streams), type `.radio`.
    var radioProvider: RadioProvider { RadioProvider.shared }

    /// All active sources.
    var allProviders: [any AudioProvider] {
        [provider, localProvider, rssProvider, absPodcastProvider, subsonicProvider,
         jellyfinProvider, radioProvider, FreeCatalogProvider.shared]
    }

    /// Routes an item to its source by id prefix. This is the ONLY place allowed
    /// to know id namespaces (the router).
    /// Which server owns a queued position, and under which name.
    ///
    /// Beside the router, because it IS the router asked for one purpose:
    /// the offline queue holds one entry per title and used to hand all of
    /// them to whatever client the caller had, which was always the main
    /// one. A `jf:` position was then offered to the library server.
    ///
    /// Nil where nobody owns the namespace. The router answers such an id
    /// with a provider that REFUSES, and sending the write there would be
    /// the same mistake one step later.
    func progressTarget(for itemId: String) -> ProgressTarget? {
        let owner = provider(for: itemId)
        guard !(owner is UnknownSourceProvider) else { return nil }
        return ProgressTarget(key: owner.providerId, client: owner)
    }

    func provider(for itemId: String) -> any AudioProvider {
        if itemId.hasPrefix("local:") { return localProvider }
        if itemId.hasPrefix("abspod:") { return absPodcastProvider }
        if itemId.hasPrefix("rss:") { return rssProvider }
        if itemId.hasPrefix("sub:") { return subsonicProvider }
        if itemId.hasPrefix("jf:") { return jellyfinProvider }
        if itemId.hasPrefix("radio:") { return radioProvider }
        // Ask the SOURCE for its namespaces instead of repeating them
        // here. The literal list is exactly what went stale when Gutenberg
        // arrived.
        if FreeCatalog.allPrefixes.contains(where: itemId.hasPrefix) {
            return FreeCatalogProvider.shared
        }
        // The ROUTER now follows the rule too, not just the two
        // callers that asked. An id whose namespace belongs to nobody gets a
        // provider that refuses (and says so). So all eleven callers, and any
        // future one, are covered without making the return type optional.
        guard ItemNamespace.mayReachLibraryServer(itemId) else {
            return UnknownSourceProvider.shared
        }
        return provider
    }

    /// Cover URL of any item via ITS source. Views must never assume a fixed
    /// provider (else wrong/no cover for local files and podcast episodes).
    func coverURL(forItemId itemId: String) -> URL? {
        // An id from an unknown namespace must NEVER turn
        // into a request to the library server. This is the path that produced
        // the 404 storm (FeedArtwork → here → ABS, token in the query string),
        // so the guard sits here, not only in the prefix list above.
        guard ItemNamespace.isKnown(itemId) else {
            Logger.library.warning(
                "ROUTER: unknown namespace \(ItemNamespace.of(itemId) ?? "-", privacy: .public) — no cover request")
            return nil
        }
        return provider(for: itemId).coverURL(forItemId: itemId)
    }

    /// Finds the `LibraryItem` for an id across ALL sources. For the global
    /// Up-Next queue (render + cross-media auto-continue), resume/restore, the
    /// widget and CarPlay. Type-complete (T3/T5): podcast episodes from their
    /// provider, music from the Subsonic item cache, audiobooks/local titles
    /// from the loaded library list. Best-effort. An id never seen yet is nil,
    /// which every caller already tolerates.
    func libraryItem(forId itemId: String) -> LibraryItem? {
        if itemId.hasPrefix("rss:") {
            return rssProvider.libraryItem(forEpisodeId: itemId)   // O(1) via the guid index
        }
        if itemId.hasPrefix("abspod:") {
            return absPodcastProvider.libraryItem(forEpisodeId: itemId)
        }
        if itemId.hasPrefix("sub:") {
            return subsonicProvider.libraryItem(forId: itemId)
        }
        if itemId.hasPrefix("jf:") {
            return jellyfinProvider.libraryItem(forId: itemId)
        }
        if itemId.hasPrefix("radio:") {
            return radioProvider.libraryItem(forId: itemId)
        }
        if FreeCatalog.allPrefixes.contains(where: itemId.hasPrefix) {
            return FreeCatalogProvider.shared.libraryItem(forId: itemId)
        }
        // An unknown namespace is nobody's. Do not look it up in the library.
        guard ItemNamespace.isKnown(itemId) else { return nil }
        // Audiobooks / local titles from the loaded library list.
        return libraryViewModel.libraryItem(forId: itemId)
    }

    /// The item to hand the PLAYER for an id. Where "not in memory" must not
    /// mean "does not exist".
    ///
    /// A catalogue id is self-describing: `fetchItemDetail` can resolve it at
    /// any time, the session cache is only a shortcut. Three surfaces treated
    /// the cache miss as nonexistence. The playlist row went dead, the queue
    /// went visually empty, the advancer ended silently. For entries the app
    /// could have fetched a second later. For every other namespace the cache
    /// answer stays authoritative (a server title without its server really is
    /// unavailable here).
    func playableItem(forId itemId: String) -> LibraryItem? {
        resolve(forId: itemId, carried: nil).item
    }

    // MARK: - The sync seam (SyncCarried), wired to what this device knows

    /// What an item carries when it travels: taken from what this device
    /// knows about it right now. Nil when it cannot name it.
    func carried(forId itemId: String) -> CarriedItem? {
        SyncCarried.snapshot(forId: itemId, known: libraryItem(forId: itemId),
                             coverURL: coverURL(forItemId: itemId))
    }

    /// What this device makes of an id plus its carried snapshot: a
    /// playable item, or the reason it is not playable here. THE answer
    /// every surface that shows travelled entries asks (playlists, queue,
    /// standby); no surface decides on its own what resolves.
    func resolve(forId itemId: String, carried: CarriedItem?) -> ItemResolution {
        SyncCarried.resolve(itemId: itemId, carried: carried,
                            known: libraryItem(forId: itemId),
                            sourceConfigured: provider(for: itemId).isAvailable)
    }

    /// THE asynchronous resolver: the seam's answer, and when it has none, a
    /// detail fetch from the id's provider (a server song the session cache
    /// does not carry, a catalogue id fetched for its metadata). The three
    /// resolvers of old (session, library route, standby) are this one.
    func resolveItem(forId itemId: String) async -> LibraryItem? {
        if let item = resolve(forId: itemId, carried: nil).item, item.media != nil { return item }
        if let detail = try? await provider(for: itemId).fetchItemDetail(itemId: itemId) {
            return LibraryItem(id: detail.id, media: detail.media, addedAt: nil)
        }
        // A catalogue stub without a fetchable detail still plays from its id.
        return resolve(forId: itemId, carried: nil).item
    }

    private(set) lazy var libraryViewModel = LibraryViewModel(provider: provider)
    private(set) lazy var playerCoordinator = PlayerCoordinator(provider: provider)

    private init() {}
}
