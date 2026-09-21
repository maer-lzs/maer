// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What a music source still needs before it can be asked anything, and the
/// sentence that says it.
///
/// **Measured, which is why this is a rule and not a string.** The test
/// button on the Jellyfin page answered *„Enter server, username and
/// password"* to somebody whose server, username and password were all
/// filled in; what was missing was the source's own switch. The guard behind
/// it had TWO causes (switch off, address empty) and its sentence named
/// THREE other things, of which exactly one was checked.
///
/// The order is the order of the page, so the sentence always names the step
/// the person does NEXT: the address and the account are typed in, and the
/// switch sits above them.
nonisolated enum SourceReadiness: Equatable {
    case address
    case account
    /// The source's OWN switch, the one on this page.
    case switchedOff
    /// The switch is on and the source is still not live: every area it
    /// feeds is switched off, or it feeds none. **This case exists because
    /// the value that decides is COMPOSED** (`tabEnabled && sourceEnabled`,
    /// for some sources plus "does it serve this kind at all"), and a
    /// sentence that named the switch for all of that told people their
    /// switched-on switch was off. What this page owns is resolved; the
    /// rest is left open rather than guessed.
    case noAreaOn

    /// `nil` means the source can be asked. The switch is asked LAST on
    /// purpose: telling somebody to flip a switch while the fields below it
    /// are still empty would send them back down the page.
    /// `sourceEnabled` is the switch on THIS page, `active` the composed
    /// answer the provider hangs on. Both are needed: only their difference
    /// tells the switch apart from everything else that can switch a source
    /// off, and only one of the two may be named in a sentence.
    static func missing(active: Bool, sourceEnabled: Bool,
                        address: String, username: String) -> SourceReadiness? {
        if address.trimmingCharacters(in: .whitespaces).isEmpty { return .address }
        if username.trimmingCharacters(in: .whitespaces).isEmpty { return .account }
        if !sourceEnabled { return .switchedOff }
        if !active { return .noAreaOn }
        return nil
    }

    /// Whether the page's test button can even form a request. The SWITCH is
    /// deliberately NOT part of this: a button that refuses without saying
    /// why is worse than one that answers with the reason, so the switch is
    /// answered by a sentence and not by a grey button.
    static func fieldsFilled(address: String, username: String) -> Bool {
        missing(active: true, sourceEnabled: true, address: address, username: username) == nil
    }

    /// One sentence per cause, each naming what is really missing.
    var sentence: String {
        switch self {
        case .address: return String(localized: "Enter the server address.")
        case .account: return String(localized: "Enter your username and password.")
        case .switchedOff: return String(localized: "Turn this source on first: the switch above is off.")
        case .noAreaOn:
            return String(localized: "This source is on, but none of the areas it feeds is switched on.")
        }
    }
}
