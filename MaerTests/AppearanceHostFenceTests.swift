// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import SwiftUI
@testable import Maer

/// The chosen appearance holds in every leaf. A sheet and a full-screen
/// cover are presentation hosts of their own: the root's preference never
/// reaches them, so each of them carries the ONE building block. A leaf
/// that keeps its own scheme on purpose stands in the exception list, by
/// name and with a reason.
struct AppearanceHostFenceTests {
    /// Presentations that deliberately do NOT follow the choice.
    /// Drive mode is always dark: it is meant to be read at a glance in a
    /// car, in the dark, whatever the app looks like elsewhere.
    static let exceptions = ["LibraryView.swift": 1]

    static let marker = "followsAppearanceChoice()"

    @Test("Jedes Blatt traegt die Wahl: je Datei so viele Bausteine wie Blaetter, Ausnahmen namentlich")
    func everyPresentedLeafCarriesTheChoice() throws {
        // Per file, the presentations that do not carry the choice; the
        // exceptions are that count, both ways.
        var uncarried: [String: Int] = [:]
        for file in ProjectFileIntegrityTests.sourceFiles() where file.path.contains("/Sources/") {
            let text = try String(contentsOf: file, encoding: .utf8)
            let code = text.split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            let presentations = code.components(separatedBy: ".sheet(").count - 1
                + code.components(separatedBy: ".fullScreenCover(").count - 1
            guard presentations > 0 else { continue }
            let carried = code.components(separatedBy: Self.marker).count - 1
            if presentations > carried { uncarried[file.lastPathComponent, default: 0] += presentations - carried }
        }
        let drift = StockDrift.findings(counts: uncarried, stock: Self.exceptions)
        #expect(drift.isEmpty, "these presentations do not follow the appearance, or an exception is stale: \(drift)")
    }

    @Test("Der Pruefer sieht den Unterschied: eine Praesentation ohne Baustein faellt auf, eine im Kommentar zaehlt nicht")
    func theCheckerWouldSeeIt() {
        func offends(_ source: String, allowed: Int = 0) -> Bool {
            let code = source.split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            let presentations = code.components(separatedBy: ".sheet(").count - 1
                + code.components(separatedBy: ".fullScreenCover(").count - 1
            let carried = code.components(separatedBy: AppearanceHostFenceTests.marker).count - 1
            return presentations > 0 && carried + allowed < presentations
        }
        #expect(offends(".sheet(isPresented: $x) { Panel() }"), "a bare sheet is a finding")
        #expect(!offends(".sheet(isPresented: $x) { Panel().followsAppearanceChoice() }"))
        #expect(!offends(".fullScreenCover(isPresented: $x) { DriveModeView() }", allowed: 1), "the named exception passes")
        #expect(offends("// .sheet(isPresented: $x) { Panel().followsAppearanceChoice() }\n.sheet(isPresented: $y) { P() }"),
                "a marker in a comment carries nothing")
    }

    @Test("Die Wahl liest EINE Stelle: system folgt dem Geraet, hell und dunkel setzen sich durch, Unbekanntes folgt dem System")
    func theChoiceIsReadInOnePlace() throws {
        #expect(AppearanceChoice.of("light") == .light)
        #expect(AppearanceChoice.of("dark") == .dark)
        #expect(AppearanceChoice.of("system") == .system)
        #expect(AppearanceChoice.of(nil) == .system)
        #expect(AppearanceChoice.of("sepia") == .system, "an unknown value is no decision")
        // The scheme the host hands SwiftUI: light and dark set it, the
        // system choice hands over nothing.
        #expect(AppearanceHost.scheme(AppearanceChoice.of("light")) == .light)
        #expect(AppearanceHost.scheme(AppearanceChoice.of("dark")) == .dark)
        #expect(AppearanceHost.scheme(AppearanceChoice.of("system")) == nil)
        // Nobody else maps the stored string to a scheme.
        var readers: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() where file.path.contains("/Sources/") {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("preferredColorScheme") else { continue }
            if !["AppearanceHost.swift", "DriveModeView.swift"].contains(file.lastPathComponent) {
                readers.append(file.lastPathComponent)
            }
        }
        #expect(readers.isEmpty, "these files set a colour scheme beside the building block: \(readers)")
    }
}
#endif
