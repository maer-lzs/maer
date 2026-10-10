// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The provider for ids whose namespace belongs to nobody.
///
/// The routing rule was turned around once. But only `coverURL` and
/// `libraryItem(forId:)` actually asked. `provider(for:)` itself still
/// returned the LIBRARY provider for an unknown namespace, and it has eleven
/// callers.
/// The most telling one is `PlayerCoordinator` resuming a STORED `lastId`: an
/// id from a removed or renamed source sits in the defaults and would go to the
/// user's server. The same mechanic that can lock someone out, only rarer.
///
/// A test for a rule the production code never reads is a green fence around
/// nothing. Hence this: the router can keep its non-optional signature, and
/// every caller, including ones nobody has written yet, is covered.
///
/// It is deliberately NOT silent: each access logs which namespace
/// was refused, and `fetchItemDetail` throws instead of returning an empty
/// husk that a caller would render as a real item.
@MainActor
final class UnknownSourceProvider: AudioProvider {
    static let shared = UnknownSourceProvider()

    private init() {}

    var providerId: String { "unknown" }
    var keepsMarksOnDevice: Bool { false }
    var capabilities: ProviderCapabilities { [] }
    /// Never offer this source anywhere in the UI.
    var isAvailable: Bool { false }
    var streamAuthHeaders: [String: String] { [:] }

    private func refuse(_ what: String, _ itemId: String) {
        Logger.library.warning(
            "ROUTER: \(what, privacy: .public) refused — unknown namespace \(ItemNamespace.of(itemId) ?? "-", privacy: .public)")
    }

    func fetchLibraries() async throws -> [ABSLibrary] { [] }
    func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] { [] }

    func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
        refuse("detail", itemId)
        // A real error, not an empty item: the caller must not render a husk.
        throw APIError.http(404, "unknown id namespace")
    }

    func coverURL(forItemId itemId: String) -> URL? {
        refuse("cover", itemId)
        return nil
    }

    func streamURL(forContentPath contentPath: String) -> URL? {
        refuse("stream", contentPath)
        return nil
    }

    // ProgressSyncAPI: nothing to sync for an id nobody owns. And above all
    // no write to a server that does not know it.
    func fetchAllProgress() async throws -> [String: BookProgress] { [:] }

    func updateProgress(itemId: String, currentTime: Double,
                        duration: Double, isFinished: Bool) async throws {
        refuse("updateProgress", itemId)
    }

    func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }

    func createBookmark(itemId: String, time: Double, title: String) async throws {
        refuse("createBookmark", itemId)
    }

    func deleteBookmark(itemId: String, time: Double) async throws {
        refuse("deleteBookmark", itemId)
    }
}
