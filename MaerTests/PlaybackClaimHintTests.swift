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
    @Test("Der Hinweis ersetzt die Standby-Zeile: oben was dort spielt, darunter das Geraet; dasselbe Stueck behaelt den eigenen Titel")
    func theHintReplacesTheStandbyLine() {
        let foreign = PlaybackClaim(deviceId: "dev-ipad", itemId: "rss:f:eurotrash", t: 1, title: "Eurotrash", deviceName: "iPad")
        let lines = PlaybackClaimRules.hintLines(claim: foreign, ownTitle: "97. Top Ten Mistresses", ownItemId: "rss:f:mistresses")
        #expect(lines.title == "Eurotrash", "the standby title gives way to what plays there")
        #expect(lines.subtitle.contains("iPad") && !lines.subtitle.contains("Eurotrash"),
                "the device line names the device, not the title again")
        let same = PlaybackClaimRules.hintLines(claim: foreign, ownTitle: "Eurotrash", ownItemId: "rss:f:eurotrash")
        #expect(same.title == "Eurotrash" && same.subtitle.contains("iPad"))
        let untitled = PlaybackClaim(deviceId: "dev-ipad", itemId: "radio:x", t: 1, title: nil, deviceName: "iPad")
        #expect(PlaybackClaimRules.hintLines(claim: untitled, ownTitle: "Own", ownItemId: "rss:f:a").title == "Own",
                "a claim without a title leaves the own title standing")
    }

    @Test("Der Geraetename reist im Anspruch; ein alter Anspruch ohne Namen liest sich weiter")
    func deviceNameTravels() {
        let named = PlaybackClaim(deviceId: "dev-a", itemId: "lva:x#3", t: 42, title: "Track", deviceName: "iPad")
        #expect(PlaybackClaim.from(plist: named.plist) == named)
        #expect(named.plist["name"] as? String == "iPad")
        let old: [String: Any] = ["device": "dev-b", "item": "rss:f:ep", "t": 7.0, "title": "Ep"]
        #expect(PlaybackClaim.from(plist: old)?.deviceName == nil)
    }

    @Test("Play im Mini-Player: bei fremdem Anspruch auf eine andere Folge oeffnet er GENAU diese, sonst schaltet er die eigene Sitzung")
    func miniPlayOpensTheClaimedEpisode() {
        let now = 1_000_000.0
        let foreign = PlaybackClaim(deviceId: "dev-ipad", itemId: "rss:f:ep-42", t: now - 1_000, title: "Ep 42", deviceName: "iPad")
        let other = PlaybackClaimRules.miniPlayAction(claim: foreign, ownDeviceId: "dev-iphone", ownItemId: "rss:f:ep-41",
                                                      isPlaying: false, nowMs: now)
        #expect(other == .openClaim("rss:f:ep-42"), "the neighbour on the bar is not the claim")
        let same = PlaybackClaimRules.miniPlayAction(claim: foreign, ownDeviceId: "dev-iphone", ownItemId: "rss:f:ep-42",
                                                     isPlaying: false, nowMs: now)
        #expect(same == .toggle, "the bar already holds the claimed episode: play takes over")
        let playing = PlaybackClaimRules.miniPlayAction(claim: foreign, ownDeviceId: "dev-iphone", ownItemId: "rss:f:ep-41",
                                                        isPlaying: true, nowMs: now)
        #expect(playing == .toggle, "while playing the button is pause")
        let own = PlaybackClaimRules.miniPlayAction(claim: foreign, ownDeviceId: "dev-ipad", ownItemId: "rss:f:ep-41",
                                                    isPlaying: false, nowMs: now)
        #expect(own == .toggle, "the own claim is no foreign claim")
        #expect(PlaybackClaimRules.miniPlayAction(claim: nil, ownDeviceId: "dev-iphone", ownItemId: nil,
                                                  isPlaying: false, nowMs: now) == .toggle)
    }

    @Test("die Geraete-Zeile nennt das Geraet, ohne Namen ein anderes Geraet")
    func theDeviceLine() {
        let claim = PlaybackClaim(deviceId: "dev-a", itemId: "abs:1q84", t: 1, title: "1Q84 (Unabridged)", deviceName: "iPad")
        let lines = PlaybackClaimRules.hintLines(claim: claim, ownTitle: "Own", ownItemId: "abs:other")
        #expect(lines.subtitle.contains("iPad") && !lines.subtitle.contains("1Q84"), "the title stands in its own line")
        let unnamed = PlaybackClaim(deviceId: "dev-a", itemId: "abs:1q84", t: 1, title: "1Q84")
        let line = PlaybackClaimRules.hintLines(claim: unnamed, ownTitle: "Own", ownItemId: nil).subtitle
        // The key form: the same lookup the rule makes, whatever the test language.
        #expect(line.contains(String(localized: "another device")))
    }
}
#endif
