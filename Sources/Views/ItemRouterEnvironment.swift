// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// What a surface may ask about an item id without knowing WHICH source
/// answers. The first question is the address of its cover.
///
/// Unlike the online answer there is no harmless fallback here: a router that
/// knows nothing returns no address, and pictures would quietly stop
/// appearing. So the DEFAULT is the real one, the way `\.dismiss` and
/// `\.openURL` have working defaults, and a preview or a witness substitutes
/// its own. Be honest about what that buys: the views become substitutable,
/// the coupling is not solved. The grip moves from every leaf into this one
/// file, and the second counter of the growth fence shows it as a move.
///
/// Why the address is ASKED and not carried with the item: it is built from
/// the server address and the token, and both can change while the app runs
/// (a new sign-in, a different server). A carried address would go stale
/// silently, and a picture that fails with 401 looks exactly like a missing
/// cover. That mistake cost a long hunt once already.
///
/// Open question, deliberately carried rather than settled: whether the
/// address belongs here at all or on the PROVIDER of the item. It is the
/// bigger half of this seam, and if it ends up there, this step was a
/// stopover.
struct ItemRouter: Sendable {
    /// Every question defaults to the session's own answer, so the plain
    /// `ItemRouter()` IS the live one and a witness overrides only the one
    /// question it cares about.
    ///
    /// The flip side, which is easy to miss: the questions a witness does
    /// NOT override then answer for real, out of the session. A witness that
    /// drives a surface asking two of them is half isolated without anyone
    /// seeing it, and its assertions depend on live state, which makes them
    /// either flaky or empty. `ItemRouter.empty` answers nothing at all, so
    /// a witness can choose between convenient and isolated instead of
    /// getting the mix by accident.
    ///
    /// The address of the item's cover.
    var coverURL: @MainActor @Sendable (String) -> URL? = {
        AppSession.shared.coverURL(forItemId: $0)
    }
    /// The item behind an id, from whichever source holds it. Nil for an id
    /// nobody has seen yet, which every caller already tolerates.
    var item: @MainActor @Sendable (String) -> LibraryItem? = {
        AppSession.shared.libraryItem(forId: $0)
    }
    /// The item in a form that can start playing, or nil.
    var playable: @MainActor @Sendable (String) -> LibraryItem? = {
        AppSession.shared.playableItem(forId: $0)
    }
    /// The source that answers for an id.
    var provider: @MainActor @Sendable (String) -> any AudioProvider = {
        AppSession.shared.provider(for: $0)
    }
    /// The full verdict for an id, including why it cannot play.
    var resolve: @MainActor @Sendable (String, CarriedItem?) -> ItemResolution = {
        AppSession.shared.resolve(forId: $0, carried: $1)
    }
    /// The source capsule of a music entry: its server's name while two
    /// music servers are active, nil otherwise (F5b-4).
    var sourceLabel: @MainActor @Sendable (String) -> String? = {
        AppSession.shared.musicSourceLabel(forItemId: $0)
    }

    static let live = ItemRouter()

    /// Answers nothing, for a witness that wants a surface fully cut off
    /// from the session. `provider` has no empty answer, so it keeps the
    /// live one; a surface that reaches for a provider is not isolatable
    /// this way, and that is worth seeing rather than hiding.
    static let empty = ItemRouter(
        coverURL: { _ in nil },
        item: { _ in nil },
        playable: { _ in nil },
        resolve: { _, _ in .unavailable(.unknownSource) },
        sourceLabel: { _ in nil })
}

private struct ItemRouterKey: EnvironmentKey {
    static let defaultValue = ItemRouter.live
}

extension EnvironmentValues {
    var itemRouter: ItemRouter {
        get { self[ItemRouterKey.self] }
        set { self[ItemRouterKey.self] = newValue }
    }
}
