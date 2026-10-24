// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Whether the window allows only upright: the folded iPhone Duo (its hinge
/// closed), because folded on its side the side column has no room and the
/// camera sits in the content (decided 24.10.2026). Open, on an iPhone or
/// an iPad (no hinge) the window keeps the Info.plist's own set.
nonisolated enum FoldOrientation {
    /// `hingeClosed` is nil where the device has no hinge.
    static func uprightOnly(hingeClosed: Bool?) -> Bool {
        hingeClosed == true
    }
}
