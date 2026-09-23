// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// What a surface may ask about a catalogue item: the one door to the
/// catalogue's register, in the shape of `\.itemRouter`. The loaders fill
/// the register when they enter an item, so every answer here is already
/// there; nothing is fetched.
///
/// The live door is the default, so a surface that never names it keeps
/// working; a witness substitutes `.empty`, which answers nothing and never
/// touches the register. Only questions a VIEW asks stand here.
struct CatalogFacts: Sendable {
    /// Where tapping a catalogue item leads: its parts list, or its page.
    var route: @MainActor @Sendable (String) -> FreeAudiobooksRoute = {
        CatalogFacts.route(itemId: $0, hasParts: CatalogFacts.register.hasPartsList(itemId: $0))
    }
    /// The stated licence, as the tile and the detail show it.
    var licence: @MainActor @Sendable (String) -> String? = {
        CatalogFacts.register.licence(forItemId: $0)
    }
    /// Which reading of a work this item is, where there are several.
    var readingVersion: @MainActor @Sendable (String) -> Int? = {
        CatalogFacts.register.readingVersion(forItemId: $0)
    }
    /// Work, album or bundle, read from the item's collections.
    var archiveForm: @MainActor @Sendable (String) -> ArchiveItemForm? = {
        CatalogFacts.register.archiveForm(itemId: $0)
    }
    var librivoxBook: @MainActor @Sendable (String) -> LibriVoxBook? = {
        CatalogFacts.register.librivoxBook(forId: $0)
    }
    var jamendoTrack: @MainActor @Sendable (String) -> JamendoTrack? = {
        CatalogFacts.register.jamendoTrack(forId: $0)
    }
    /// The page at the source that the item came from.
    var sourceURL: @MainActor @Sendable (String) -> URL? = {
        CatalogFacts.register.sourceURL(forItemId: $0)
    }

    /// The door's one grip on the register.
    @MainActor private static var register: FreeCatalogProvider { FreeCatalogProvider.shared }

    static let live = CatalogFacts()

    /// Answers nothing: an item without facts opens its own page.
    static let empty = CatalogFacts(
        route: { .catalogBook(itemId: $0) },
        licence: { _ in nil },
        readingVersion: { _ in nil },
        archiveForm: { _ in nil },
        librivoxBook: { _ in nil },
        jamendoTrack: { _ in nil },
        sourceURL: { _ in nil })

    /// The one decision five tiles made word for word: an item with a parts
    /// list opens the list, every other item its own page.
    nonisolated static func route(itemId: String, hasParts: Bool) -> FreeAudiobooksRoute {
        hasParts ? .series(itemId: itemId) : .catalogBook(itemId: itemId)
    }
}

private struct CatalogFactsKey: EnvironmentKey {
    static let defaultValue = CatalogFacts.live
}

extension EnvironmentValues {
    var catalogFacts: CatalogFacts {
        get { self[CatalogFactsKey.self] }
        set { self[CatalogFactsKey.self] = newValue }
    }
}
