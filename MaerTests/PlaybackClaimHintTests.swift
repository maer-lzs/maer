// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The hint names the device and the title in ONE line; the device's name
/// rides the claim and an older claim without it still reads.
struct PlaybackClaimHintTests {
    @Test("Der Geraetename reist im Anspruch; ein alter Anspruch ohne Namen liest sich weiter")
    func deviceNameTravels() {
        let named = PlaybackClaim(deviceId: "dev-a", itemId: "lva:x#3", t: 42, title: "Track", deviceName: "iPad")
        #expect(PlaybackClaim.from(plist: named.plist) == named)
        #expect(named.plist["name"] as? String == "iPad")
        let old: [String: Any] = ["device": "dev-b", "item": "rss:f:ep", "t": 7.0, "title": "Ep"]
        #expect(PlaybackClaim.from(plist: old)?.deviceName == nil)
    }

    @Test("Eine Zeile: Geraet und Titel, nur Geraet bei gleichem Titel, anderes Geraet ohne Namen")
    func oneLine() {
        let claim = PlaybackClaim(deviceId: "dev-a", itemId: "abs:1q84", t: 1, title: "1Q84 (Unabridged)", deviceName: "iPad")
        let full = PlaybackClaimRules.hintLine(claim: claim, ownItemId: "abs:other")
        #expect(full.contains("iPad") && full.contains("1Q84 (Unabridged)"))
        #expect(!full.contains("·"), "one sentence, not two joined parts")
        let same = PlaybackClaimRules.hintLine(claim: claim, ownItemId: "abs:1q84")
        #expect(same.contains("iPad") && !same.contains("1Q84"))
        let unnamed = PlaybackClaim(deviceId: "dev-a", itemId: "abs:1q84", t: 1, title: "1Q84")
        let line = PlaybackClaimRules.hintLine(claim: unnamed, ownItemId: nil)
        #expect(line.contains("another device") || line.contains("anderem Gerät") || line.contains("anderes Gerät"))
    }
}
#endif
