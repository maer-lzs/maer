// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// What `timeoutInterval` does to a socket, held as it was MEASURED against
/// a silent WebSocket on the loopback, because the name says the opposite:
///
/// | probe | result |
/// |---|---|
/// | 5 s on the request, silent open socket | stood 25 s |
/// | 60 s on the request, silent open socket | stood 95 s |
/// | 5 s on the request, upgrade never answered | `-1001` after 5 s |
///
/// So the value is the deadline of the UPGRADE, and a standing connection is
/// not governed by it at all. It therefore stays short here, and the device
/// symptom it was suspected of causing (a socket that ended after 32 to 200
/// seconds with `-1001`) has a different cause, still open.
struct SocketLaneTimeoutTests {
    static let adresse = URL(string: "ws://127.0.0.1:1/v1/changes")!

    @Test("die Socket-Tuer setzt die Frist des Aufstiegs selbst, statt sie zu erben")
    func theSocketDoorSetsTheUpgradeDeadlineItself() throws {
        let nackt = URLRequest(url: Self.adresse)
        // Was ein selbst gebauter Request mitbringt, wenn niemand etwas sagt.
        #expect(nackt.timeoutInterval == 60, "URLRequest bringt nicht mehr 60 Sekunden mit")

        let aufgabe = HTTP.webSocket(for: nackt)
        defer { aufgabe.cancel() }
        let gestellt = try #require(aufgabe.originalRequest)
        #expect(gestellt.timeoutInterval == HTTP.socketUpgradeTimeout,
                "die Tuer laesst die Frist dem Zufall der Rufstelle")
        #expect(HTTP.socketUpgradeTimeout == 60)
        // Und ausdruecklich NICHT die Stunde der Sitzung: ein Aufstieg, den
        // niemand beantwortet, wuerde sonst eine Stunde haengen.
        #expect(gestellt.timeoutInterval < URLSession.socket.configuration.timeoutIntervalForRequest,
                "die Frist des Aufstiegs ist die der Sitzung geworden")
    }

    /// Die Tuer BESITZT die Frist des Aufstiegs, sie erbt sie nicht: eine
    /// Rufstelle, die eine eigene mitbringt, bekommt trotzdem die der Spur.
    /// Eine Ausnahme waere nicht unterscheidbar von der Vorgabe, die
    /// URLRequest ohnehin mitbringt, und damit keine Regel.
    @Test("die Frist gehoert der Spur, nicht der Rufstelle")
    func theDeadlineBelongsToTheLaneNotTheCallSite() throws {
        var eigen = URLRequest(url: Self.adresse)
        eigen.timeoutInterval = 12
        let aufgabe = HTTP.webSocket(for: eigen)
        defer { aufgabe.cancel() }
        #expect(aufgabe.originalRequest?.timeoutInterval == HTTP.socketUpgradeTimeout)
    }

    /// Der Socket kommt aus genau EINER Tuer, sonst baut die naechste
    /// Rufstelle ihren eigenen Request und erbt still, was URLRequest
    /// vorgibt.
    @Test("eine Socket-Aufgabe entsteht nur an der einen Tuer", .needsTheSources)
    func aSocketTaskIsMadeAtOneDoorOnly() throws {
        let wurzel = SourceTree.root.appendingPathComponent("Sources")
        let dateien = SourceTree.files(under: wurzel)
            .filter { $0.pathExtension == "swift" }
        try #require(dateien.count > 100, "der Zaun hat den Quellbaum nicht gelesen")
        var stellen: [String] = []
        for datei in dateien {
            let text = try String(contentsOf: datei, encoding: .utf8)
            for zeile in text.components(separatedBy: "\n") {
                let blank = zeile.trimmingCharacters(in: .whitespaces)
                if blank.hasPrefix("//") { continue }
                if blank.contains("webSocketTask(with:") { stellen.append(datei.lastPathComponent) }
            }
        }
        #expect(stellen == ["HTTP.swift"], "Socket-Aufgaben entstehen ausserhalb der Tuer: \(stellen)")
    }
}
#endif
