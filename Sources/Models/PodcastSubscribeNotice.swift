// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// When does subscribing have to say something?
///
/// A feed that parses into a valid show but carries no episode becomes a
/// subscription like any other (a deliberate rule: a 200 answer full of
/// garbage must not become a show, an image plus a title may). The show then
/// stands in the subscription list and is invisible in the tab, because a
/// section only takes a show whose newest episode has a date. Whoever
/// subscribed had no way to find out why nothing appeared.
///
/// Product decision of 09.09.2026: SAY it at the moment of subscribing. The
/// subscription still happens, because the person asked for this address and
/// the feed may carry episodes tomorrow. What is taken away is the riddle,
/// not the choice.
nonisolated enum PodcastSubscribeNotice {
    /// The three facts that decide it, and none of them is a view's business:
    ///
    /// - `isUserAction`: a subscription arriving from the account or from a
    ///   gpodder server is nobody's tap. A message about it would appear out
    ///   of nowhere, with nothing to act on.
    /// - `isFirstSubscribe`: re-subscribing MERGES with what is cached, so a
    ///   thin second parse loses no episodes and is worth no warning. Only a
    ///   show that enters the store empty is silent afterwards.
    /// - `episodeCount`: the reason itself.
    static func shouldTell(episodeCount: Int, isUserAction: Bool, isFirstSubscribe: Bool) -> Bool {
        isUserAction && isFirstSubscribe && episodeCount == 0
    }
}
