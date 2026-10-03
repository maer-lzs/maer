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
    @Test("ein Kanal, den der Server nicht mehr fuehrt, steht nach dem Spiegel in keiner Menge")
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

    @Test("das Ergebnis der Wiederaufnahme: Mitglied, sonst der Grund (Schalter, Liste)")
    func theOutcomeIsMembershipOrTheReason() {
        func outcome(_ sourceOn: Bool, _ active: Bool, server: Bool = true, _ member: Bool) -> PinchflatMirror.ReadmitOutcome {
            PinchflatMirror.readmitOutcome(sourceOn: sourceOn, active: active, serverKnown: server, member: member)
        }
        #expect(outcome(true, true, true) == .joined)
        #expect(outcome(true, true, false) == .notListed)
        #expect(outcome(false, false, false) == .switchedOff)
        #expect(outcome(false, false, true) == .switchedOff,
                "with the source off nothing joined, whatever the store still holds")
        // Der Schalter ist AN, nur der Reiter ist aus. Vorher bekam die
        // Person hier „die Quelle ist ausgeschaltet" ueber einen Schalter,
        // den sie gerade angelassen hatte.
        #expect(outcome(true, false, true) == .areaOff)
        #expect(outcome(true, false, false) == .areaOff,
                "ohne den Bereich entscheidet die Mitgliedschaft nicht mehr")
        // Ohne eingetragenen Server fragt der Spiegel keine Liste; die
        // Antwort nennt den fehlenden Server, nie die Liste des Servers.
        #expect(outcome(true, true, server: false, false) == .noServer)
        #expect(outcome(true, true, server: false, true) == .noServer,
                "without a server nothing was asked, whatever the store still holds")
        // Schalter und Bereich stehen davor: sie sind der naehere Grund.
        #expect(outcome(false, false, server: false, false) == .switchedOff)
        #expect(outcome(true, false, server: false, false) == .areaOff)
    }

    /// The page asks the membership of the channel, not the sum, and gates
    /// the button while a pass runs: a source fence, because the page is a
    /// view and the decision above is what it asks.
    @Test("die Seite fragt die Mitgliedschaft dieses Kanals und sperrt den Knopf waehrend des Durchgangs")
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
    @Test("Pinchflat ist eingerichtet, wenn die Adresse einen Host hat; die Frage steht einmal", .needsTheSources)
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
