// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What an item carries when it travels to another device: enough to be
/// SHOWN there without any local stock. Taken at the moment the item is at
/// hand, on the device that has it. Travels with playlist entries; the
/// same shape the claim and the listening rows will speak.
///
/// Never a server address with a token in it: the cover travels only when
/// its address is public (catalogue, radio). A server cover is derived on
/// the device that has the server.
nonisolated struct CarriedItem: Codable, Hashable, Sendable {
    var id: String
    var title: String
    /// Artist, author or show, whatever the source calls it.
    var subtitle: String?
    /// Seconds, when the source states one.
    var duration: Double?
    /// A public cover address, or nil.
    var coverURL: String?
    /// The namespace of the id (`lva:`, `sub:` …), or `library` for a
    /// server audiobook id without one.
    var source: String

    init(id: String, title: String, subtitle: String? = nil, duration: Double? = nil,
         coverURL: String? = nil, source: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.duration = duration
        self.coverURL = coverURL
        self.source = source ?? SyncCarried.source(of: id)
    }
}

/// Why an entry cannot be played on THIS device. A reason, never silence:
/// resolvability is a property of the device, the entry stays.
nonisolated enum UnavailableReason: Equatable, Sendable {
    /// The source is not set up here (no server of that kind).
    case sourceNotConfigured(source: String)
    /// The server is set up, but this title is not in its library here.
    case notInLibrary
    /// A local file that never lay on this device.
    case fileNotOnDevice
    /// A podcast episode of a show this device does not follow.
    case showNotFollowed
    /// A namespace nobody knows.
    case unknownSource
}

/// The answer of the seam for one id on this device.
nonisolated enum ItemResolution {
    case playable(LibraryItem)
    case unavailable(UnavailableReason)

    var item: LibraryItem? { if case .playable(let item) = self { return item } else { return nil } }
    var reason: UnavailableReason? { if case .unavailable(let reason) = self { return reason } else { return nil } }
}

/// THE seam for sync behaviour per source (Rule 2: every source, one
/// place). Two questions, answered here and nowhere else:
///
/// 1. `snapshot`: what does an item of this source carry when it travels?
/// 2. `resolve`: what does another device make of an id plus its carried
///    snapshot, with what it knows locally and which sources it has?
///
/// Pure over what the session hands in (the locally known item, whether
/// the source is set up), so the rules are witnessed per source without a
/// provider. `AppSession` wires the knowledge in.
nonisolated enum SyncCarried {
    static let catalogPrefixes = FreeCatalog.allPrefixes

    /// The namespace, or `library` for a bare server audiobook id.
    static func source(of itemId: String) -> String {
        ItemNamespace.of(itemId) ?? "library"
    }

    static func isCatalog(_ itemId: String) -> Bool {
        catalogPrefixes.contains(where: itemId.hasPrefix)
    }

    /// A public cover address may travel; a server one carries a token.
    static func coverMayTravel(_ itemId: String) -> Bool {
        isCatalog(itemId) || itemId.hasPrefix("radio:") || itemId.hasPrefix("rss:")
    }

    /// The snapshot of a locally known item. Nil when the item does not
    /// name itself (a stub, the unknown-title placeholder): a placeholder
    /// written into synced data would poison every device's rows.
    static func snapshot(forId itemId: String, known: LibraryItem?, coverURL: URL?) -> CarriedItem? {
        guard let known, let title = usableTitle(known.media?.metadata?.title, for: itemId) else { return nil }
        return CarriedItem(id: itemId, title: title, subtitle: known.author,
                           duration: known.media?.duration,
                           coverURL: coverMayTravel(itemId) ? coverURL?.absoluteString : nil)
    }

    /// A title is only worth carrying when it NAMES the entry: never the
    /// raw id, never the unknown placeholder in any language.
    static func usableTitle(_ candidate: String?, for itemId: String) -> String? {
        guard let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text != itemId else { return nil }
        let placeholders: Set<String> = ["Unknown Title", String(localized: "Unknown Title")]
        guard !placeholders.contains(text) else { return nil }
        return text
    }

    /// What this device makes of an id and its snapshot.
    ///
    /// - A locally known item plays, whatever the source.
    /// - A catalogue id is self-describing: it plays from the id alone; the
    ///   snapshot gives it its name and length until the detail is fetched.
    /// - A server title, a local file or an episode this device does not
    ///   know stays visible with its reason, never silently gone.
    static func resolve(itemId: String, carried: CarriedItem?, known: LibraryItem?,
                        sourceConfigured: Bool) -> ItemResolution {
        if let known { return .playable(known) }
        if isCatalog(itemId) { return .playable(stub(itemId: itemId, carried: carried)) }
        guard let namespace = ItemNamespace.of(itemId) else {
            // A bare id is a server audiobook: it needs its server.
            return .unavailable(sourceConfigured ? .notInLibrary : .sourceNotConfigured(source: "library"))
        }
        guard ItemNamespace.isKnown(itemId) else { return .unavailable(.unknownSource) }
        switch namespace {
        case "local:": return .unavailable(.fileNotOnDevice)
        case "rss:", "abspod:": return .unavailable(.showNotFollowed)
        default:
            return .unavailable(sourceConfigured ? .notInLibrary : .sourceNotConfigured(source: namespace))
        }
    }

    /// The item a catalogue id becomes without local stock: named by its
    /// snapshot, resolved on demand when played.
    static func stub(itemId: String, carried: CarriedItem?) -> LibraryItem {
        guard let carried else { return LibraryItem(id: itemId, media: nil, addedAt: nil) }
        return LibraryItem(
            id: itemId,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(title: carried.title, authorName: carried.subtitle,
                                              narratorName: nil, seriesName: nil, genres: nil,
                                              publishedYear: nil, description: nil),
                duration: carried.duration, chapters: nil, tracks: nil),
            addedAt: nil)
    }
}
