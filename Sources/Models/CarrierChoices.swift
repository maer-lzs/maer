// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What the factories have actually handed out in this run.
///
/// The five runners are lazy singletons and are built at different
/// moments, each taking whatever `make(access:)` answers right then. So
/// "does the service carry" is not one fact but five, and none of them is
/// the setting.
///
/// Asking a runner would be worse than useless: reading `Something.shared`
/// CREATES it, with the access of that moment, so the question would make
/// its own answer true. A surface that asks would report "in use" for a
/// carrier that came into being because it asked. This register is written
/// where the carriers are chosen and read without touching anyone.
@MainActor
enum CarrierChoices {
    /// How many carriers have been handed out at all.
    private(set) static var handedOut = 0
    /// How many of those were the Mär sync service.
    private(set) static var overTheService = 0

    /// Called by every factory, with what it just decided.
    ///
    /// The counters count HANDOUTS, not carriers: they know no identity and
    /// never fall. That holds only while every runner draws exactly once,
    /// which is what a lazy singleton does, and while `make` is called
    /// nowhere but from those five defaults. Draw twice for one runner and
    /// "everything travels the service" stops meaning what it says.
    static func note(service: Bool) {
        handedOut += 1
        if service { overTheService += 1 }
    }

    /// Whether everything that exists travels over the service.
    ///
    /// False while nothing has been built yet, and that is the honest
    /// answer: a service that nobody carries with is not in use, however
    /// well it is set up.
    static var allTravelTheService: Bool {
        handedOut > 0 && handedOut == overTheService
    }

    /// Whether ANY runner holds the service. The other question of the
    /// page: signed out with one runner still on the service is "stalled
    /// until the restart", not "your devices use iCloud", and a runner made
    /// after the others (a lazy singleton touched late) can hold the
    /// service alone.
    static var anyTravelsTheService: Bool { overTheService > 0 }

    /// Tests build carriers of their own; the counters are process-wide.
    static func forgetForTesting() {
        handedOut = 0
        overTheService = 0
    }
}
