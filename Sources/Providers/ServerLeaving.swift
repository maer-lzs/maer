// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// A server leaves the device: it signed out, or another address or
/// sign-in took its place. The one place for what it leaves behind: a
/// player on one of its titles ends first, with the mini bar (the standby
/// pointer stays), so it writes no snapshot of that title again; then its
/// titles leave the widget's rows, and the player's snapshot goes with its
/// cover when it is one of them. `owns` is the family's namespace;
/// `allRows` takes every row, for a sign out the home page computes
/// nothing after.
enum ServerLeaving {
    static func forget(_ owns: (String) -> Bool, allRows: Bool = false,
                       player: PlayerCoordinator? = nil) async {
        (player ?? AppSession.shared.playerCoordinator).endPlayback(ownedBy: owns)
        await ContinueRowsWriter.forgetServer(owns, allRows: allRows)
    }
}
