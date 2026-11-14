// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Re-admitting a hidden Pinchflat channel asks whether THIS channel is a
/// member of the group again, never how big the group is. Before: the page
/// read the mirror's total and let a channel the server had deleted vanish
/// from the hidden list as long as any other channel stood.
struct PinchflatReadmitTests {
    @Test("a channel the server no longer carries is in no set after the mirror")
    func aDeletedChannelIsInNeitherSet() {
        // Server lists A and B, the group mirrors A and B, X was just
        // unhidden: the diff neither subscribes nor unsubscribes X, so the
        // group ends with two members and X is not among them.
        let diff = PinchflatMirror.diff(serverFeeds: ["https://p/a.xml", "https://p/b.xml"],
                                        mirrored: ["https://p/a.xml", "https://p/b.xml"], hidden: [])
        #expect(diff.toSubscribe.isEmpty && diff.toUnsubscribe.isEmpty)
        let members = Set(["https://p/a.xml", "https://p/b.xml"]).union(diff.toSubscribe).subtracting(diff.toUnsubscribe)
        #expect(members.count == 2, "the group's size says nothing about X")
        #expect(!members.contains("https://p/x.xml"), "X is not a member, whatever the size")
    }

    @Test("the result of the readmission: member, otherwise the reason (switch, list)")
    func theOutcomeIsMembershipOrTheReason() {
        func outcome(_ sourceOn: Bool, _ active: Bool, server: Bool = true, _ member: Bool) -> PinchflatMirror.ReadmitOutcome {
            PinchflatMirror.readmitOutcome(sourceOn: sourceOn, active: active, serverKnown: server, member: member)
        }
        #expect(outcome(true, true, true) == .joined)
        #expect(outcome(true, true, false) == .notListed)
        #expect(outcome(false, false, false) == .switchedOff)
        #expect(outcome(false, false, true) == .switchedOff,
                "with the source off nothing joined, whatever the store still holds")
        // The switch is ON, only the tab is off. Before, the
        // person here got „die Quelle ist ausgeschaltet" about a switch
        // they had just left on.
        #expect(outcome(true, false, true) == .areaOff)
        #expect(outcome(true, false, false) == .areaOff,
                "ohne den Bereich entscheidet die Mitgliedschaft nicht mehr")
        // Without a registered server the mirror asks no list; the
        // answer names the missing server, never the list of the server.
        #expect(outcome(true, true, server: false, false) == .noServer)
        #expect(outcome(true, true, server: false, true) == .noServer,
                "without a server nothing was asked, whatever the store still holds")
        // Switch and area come first: they are the nearer reason.
        #expect(outcome(false, false, server: false, false) == .switchedOff)
        #expect(outcome(true, false, server: false, false) == .areaOff)
    }

    /// The page asks the membership of the channel, not the sum, and gates
    /// the button while a pass runs: a source fence, because the page is a
    /// view and the decision above is what it asks.
    @Test("the page asks the membership of this channel and locks the button during the pass", .needsTheSources)
    func thePageAsksTheMembershipAndGatesTheButton() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/Views/PodcastSourceView.swift"), encoding: .utf8)
        let start = try #require(text.range(of: "private func readmit("))
        let body = String(text[start.upperBound...].prefix(1400))
        #expect(body.contains("PodcastSubscriptions.shared.isMirrored(feedURL: entry.feedURL)"), "readmit does not ask the membership")
        #expect(!body.contains("mirror() > 0"), "readmit reads the group's size again")
        #expect(body.contains("pinchflatBusy = true"), "readmit does not take the busy gate")
        let button = try #require(text.range(of: "Task { await readmit(entry) }"))
        #expect(String(text[button.upperBound...].prefix(500)).contains(".disabled(pinchflatBusy)"), "the re-admit button is not gated")
    }

    /// One question, one answer: a Pinchflat server is set up when its
    /// address has a host. Two predicates (`!= nil` and `?.host`) answered
    /// differently for an address without a host.
    @Test("Pinchflat is set up when the address has a host; the question exists once", .needsTheSources)
    func configuredIsOneQuestion() throws {
        #expect(PinchflatClient.isConfigured(URL(string: "https://tube.example.test")))
        #expect(!PinchflatClient.isConfigured(URL(string: "tube")), "an address without a host is none")
        #expect(!PinchflatClient.isConfigured(nil))
        var found: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            if code.contains("serverURL != nil") {
                found.append(file.lastPathComponent)
            }
        }
        #expect(found.isEmpty, "a second answer to whether Pinchflat is set up: \(found)")
    }
}
#endif
