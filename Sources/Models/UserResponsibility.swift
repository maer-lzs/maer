// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// THE sentence about the listener's own responsibility for what the open
/// catalogs hand out. It stands once, in the settings' About section.
nonisolated enum UserResponsibility {
    static var sentence: String {
        String(localized: "Mär shows catalogues as their operators publish them openly on the internet and gives no access that does not already exist there. Mär does not check or guarantee the rights status of any recording. Whether you may listen to, download, or otherwise use a recording is your responsibility.")
    }
}
