// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What the settings page says about the feed credentials, and, in the same
/// answer, whether this device may WRITE the block.
///
/// One rule for both, deliberately: the sentence the person reads and the
/// permission to overwrite are the same question asked twice, and the way to
/// lose a bought feed is to let them drift apart. Whoever changes the
/// sentence changes the permission.
nonisolated enum FeedAuthStanding {
    /// What this device found at the far side.
    enum Block: Equatable {
        /// Nothing there yet. The first device writes it.
        case none
        /// There, and this device's key opens it.
        case opens
        /// There, readable as a block, and the key does not open it. Another
        /// device holds the key, and the code brings it here.
        case sealedForAnother
        /// There, and a newer build wrote it.
        case newerFormat(Int)
    }

    enum Standing: Equatable {
        /// The one switch is off. Nothing travels, whatever is set up here.
        case switchedOff
        /// No service account, so this is not the way the credentials take.
        case noService
        /// Set up and carrying.
        case carrying
        /// Set up, and this device needs the code from the other one.
        case needsCode
        /// A newer build wrote the block. Not our business to touch.
        case newerBuild(Int)
    }

    static func standing(syncAcrossDevices: Bool,
                         hasService: Bool,
                         block: Block) -> Standing {
        // The switch stands above everything, like everywhere else.
        guard syncAcrossDevices else { return .switchedOff }
        guard hasService else { return .noService }
        switch block {
        case .none, .opens: return .carrying
        case .sealedForAnother: return .needsCode
        case .newerFormat(let version): return .newerBuild(version)
        }
    }

    /// Something the page says BESIDE the standing, never instead of it.
    enum Notice: Equatable {
        /// The service address is plain `http`. The block itself stays
        /// sealed, but the token in the header of every request does not,
        /// and whoever reads it on the same network takes over the account.
        case plainAddress
    }

    /// **A notice, deliberately not a refusal.**
    ///
    /// The people this whole point is built for are the ones who cannot get
    /// a certificate. Refusing to carry their credentials over `http` would
    /// lock out exactly them, so the address is NAMED and carried anyway:
    /// the person is told what it means, before they rely on it, and they
    /// decide.
    ///
    /// It falls away on its own once the whole traffic runs in a sealed
    /// session, because then a plain address is no longer the difference.
    static func notice(addressIsSecure: Bool, standing: Standing) -> Notice? {
        guard !addressIsSecure else { return nil }
        // Nothing to warn about where nothing travels.
        switch standing {
        case .switchedOff, .noService: return nil
        case .carrying, .needsCode, .newerBuild: return .plainAddress
        }
    }

    /// Whether a service address is reached over a secure transport.
    ///
    /// Deliberately a question about the SCHEME and not about the host: a
    /// bare IP address and a `.local` name are exactly where the platform's
    /// own transport rule stops applying, so "it is a local network" is the
    /// reason to SAY something, never a reason to assume it is fine.
    static func addressIsSecure(_ url: String) -> Bool {
        url.lowercased().hasPrefix("https://")
    }

    /// **The rule that protects a bought feed.** A device writes the block
    /// only when it can account for everything in it.
    ///
    /// The dangerous case is the one that looks harmless: a block sealed
    /// with ANOTHER key is perfectly valid, it is simply not ours. To this
    /// device it looks exactly like damage, and the reflex on damage is to
    /// write a fresh one. That would delete every credential the other
    /// device holds, silently, and the person notices when a paid feed stops
    /// playing.
    ///
    /// So: an empty far side may be written, a block we opened may be
    /// replaced, and anything else is left alone until the person brings the
    /// code over.
    static func mayWrite(_ block: Block) -> Bool {
        switch block {
        case .none, .opens: return true
        case .sealedForAnother, .newerFormat: return false
        }
    }
}
