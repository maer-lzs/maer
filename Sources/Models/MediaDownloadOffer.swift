// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// May a download be OFFERED for this item at all?
///
/// Not every source can hand out a file. Imported local files are already on
/// the device and carry no download capability, the free catalogs carry none
/// either, and radio carries none by its nature. Only `.downloadable` sources
/// can answer a download.
///
/// The question had no place of its own, and the whole tree asked a different
/// one instead: „is it already here?". That reads the same in the common case
/// and differently in exactly the cases that matter. It also produced the
/// regression this rule repairs: the delete gate learned to ask whether WE
/// fetched something, so an imported local audiobook stopped offering „Delete
/// Download" (right) and started offering „Save for Offline" instead (wrong,
/// and with the library provider for a file that has none).
nonisolated enum MediaDownloadOffer {
    /// Only a source that can download may be offered a download. The
    /// capability lives on the item's OWN provider, never on the library's:
    /// a caller asks its router for that provider and hands in what it can.
    static func isPossible(_ capabilities: ProviderCapabilities) -> Bool {
        capabilities.contains(.downloadable)
    }
}

