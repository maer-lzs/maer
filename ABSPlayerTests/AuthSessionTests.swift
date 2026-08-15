// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// 🔴 P5: **credentials are deleted by the user, never by a server answer.**
/// A homeserver coming back up answers 401 for minutes; the old path logged
/// out and dropped the keychain token, which no restart could undo.
@MainActor
struct AuthSessionTests {
    @Test("ein 401-Dauerregen laesst den Schluessel unangetastet")
    func unauthorizedNeverDeletesTheToken() async {
        let key = "test-token-\(UUID().uuidString)"
        KeychainStore.save("SECRET-TOKEN", forKey: key)
        defer { KeychainStore.delete(forKey: key) }

        let auth = AppSession.shared.authViewModel
        // Der Dauerregen: viele 401 hintereinander, so wie das Hochfahren
        // des Reverse-Proxys sie liefert.
        for _ in 0..<25 { auth.markSessionSuspect() }

        // Der Zustand ist ZWEIFEL, nicht Abmeldung …
        #expect(auth.sessionSuspect)
        // … und der gespeicherte Schluessel liegt unveraendert im Bund.
        #expect(KeychainStore.load(forKey: key) == "SECRET-TOKEN")
    }

    @Test("die Probe trennt 'Server nicht da' von 'Server sagt nein'")
    func probeSeparatesUnreachableFromRejected() async {
        // Ohne Token ist die Frage beantwortet, ohne das Netz zu fragen.
        let client = APIClient(baseURL: URL(string: "https://example.invalid")!, token: nil)
        #expect(await client.probeAuthorization() == .rejected)
        // Mit Token, aber unerreichbarem Host: UNREACHABLE — genau das
        // Neustart-Fenster, in dem nichts angetastet werden darf.
        let offline = APIClient(baseURL: URL(string: "https://127.0.0.1:9")!, token: "T")
        #expect(await offline.probeAuthorization() == .unreachable)
    }

    @Test("nur der Nutzer-Abmelde-Weg raeumt den Schluessel")
    func onlyTheUserPathDeletes() {
        // Der Zaun in Textform: der 401-Rueckruf zeigt auf markSessionSuspect,
        // niemals auf logout(). Gemessen an der Quelle, damit ein spaeterer
        // Umbau die Regel nicht still zuruecknimmt.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Sources/ViewModels/AuthViewModel.swift")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        guard let range = text.range(of: "onUnauthorized = {") else {
            Issue.record("der 401-Rueckruf wurde umbenannt — Zaun pruefen")
            return
        }
        let handler = text[range.lowerBound...].prefix(400)
        #expect(handler.contains("markSessionSuspect"))
        #expect(!handler.contains("logout()"))
    }
}
#endif
