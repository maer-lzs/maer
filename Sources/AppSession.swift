// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine

/// Process-wide playback/library session. Coordinator and LibraryViewModel used
/// to live as @StateObject in LibraryView — on a CarPlay COLD START (the app is
/// woken only for the car scene, no UI) they did not exist at all. Here they
/// belong to the process; UI and CarPlay scene share the same instances (one
/// player, one queue).
@MainActor
final class AppSession: ObservableObject {
    static let shared = AppSession()

    /// Y37: source configuration as an OBSERVABLE state — bumped whenever a
    /// source's availability may have changed (toggle, credential change,
    /// probe result). The tab bar derives `availableMediaTypes` from
    /// `isAvailable` on every render; without this signal nothing re-rendered
    /// after a settings change, so a toggled source only appeared/disappeared
    /// on the next incidental re-render (or app restart).
    @Published private(set) var sourcesVersion = 0

    func notifySourcesChanged() {
        // A provider's FIRST touch can happen inside a body render (the tab
        // bar reads `allProviders` while rendering) and its init calls
        // reloadConfig → here. Publishing during a view update is illegal —
        // defer the bump out of the update cycle.
        Task { @MainActor in
            self.sourcesVersion += 1
        }
    }

    /// TF bib-toggles: apply a tab-master / source toggle change. Rebuilds the
    /// Subsonic client for its new active state (nil when off, so its calls
    /// stop) and refreshes the tab bar. Every library toggle in Settings calls
    /// this — the ONE entry point so a flipped toggle takes effect everywhere.
    func reconfigureSources() {
        SubsonicProvider.shared.reloadConfig()   // rebuilds/nils client + notifies
        JellyfinProvider.shared.reloadConfig()
        notifySourcesChanged()                   // toggles that don't touch the music clients
    }

    /// Owns the APIClient (built from the keychain) — base URL and token are
    /// updated IN PLACE on login, so the objects below stay valid.
    let authViewModel = AuthViewModel()

    /// The server provider (Audiobookshelf) — basis for login, library choice,
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
    /// protocol, never to a concrete server type. Stage 2: Jellyfin serves
    /// when it is the only active music source; with BOTH active, Subsonic
    /// wins for now — real exclusivity (PodcastServerExclusivity pattern) is
    /// Etappe 3.
    var musicProvider: any MusicProvider {
        if AppStorageKeys.jellyfinActive, !AppStorageKeys.subsonicActive {
            return JellyfinProvider.shared
        }
        return SubsonicProvider.shared
    }

    /// Internet radio (Radio Browser catalog + manual streams), type `.radio`.
    var radioProvider: RadioProvider { RadioProvider.shared }

    /// All active sources.
    var allProviders: [any AudioProvider] {
        [provider, localProvider, rssProvider, absPodcastProvider, subsonicProvider,
         jellyfinProvider, radioProvider]
    }

    /// Routes an item to its source by id prefix. This is the ONLY place allowed
    /// to know id namespaces (the router).
    func provider(for itemId: String) -> any AudioProvider {
        if itemId.hasPrefix("local:") { return localProvider }
        if itemId.hasPrefix("abspod:") { return absPodcastProvider }
        if itemId.hasPrefix("rss:") { return rssProvider }
        if itemId.hasPrefix("sub:") { return subsonicProvider }
        if itemId.hasPrefix("jf:") { return jellyfinProvider }
        if itemId.hasPrefix("radio:") { return radioProvider }
        return provider
    }

    /// Cover URL of any item via ITS source — views must never assume a fixed
    /// provider (else wrong/no cover for local files and podcast episodes).
    func coverURL(forItemId itemId: String) -> URL? {
        provider(for: itemId).coverURL(forItemId: itemId)
    }

    /// Finds the `LibraryItem` for an id across ALL sources — for the global
    /// Up-Next queue (render + cross-media auto-continue), resume/restore, the
    /// widget and CarPlay. Type-complete (T3/T5): podcast episodes from their
    /// provider, music from the Subsonic item cache, audiobooks/local titles
    /// from the loaded library list. Best-effort — an id never seen yet is nil,
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
        // Audiobooks / local titles from the loaded library list.
        return libraryViewModel.libraryItem(forId: itemId)
    }

    private(set) lazy var libraryViewModel = LibraryViewModel(provider: provider)
    private(set) lazy var playerCoordinator = PlayerCoordinator(provider: provider)

    private init() {}
}
