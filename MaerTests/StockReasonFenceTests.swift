// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Ein Zaun mit begruendetem Bestand ist besser als einer ohne, aber jede
/// Begruendung darin ist eine AUSSAGE UEBER DEN CODE, und die kann altern
/// oder von Anfang an danebenliegen. Vier solcher Faelle in zwei Tagen:
/// „kein neuer Beobachter" (es war einer), `MusicView` als Helfer ohne
/// eigenes `self` (es war ein `ViewModifier`), ein Zeuge, der eine Adresse
/// mit sich selbst verglich (beide nil), und ein Bestandsgrund, der eine
/// Datei nannte, die nicht im Bestand steht. Jedes Mal war der BAU richtig
/// und der Satz daneben falsch, und keiner dieser Fehler wird je rot.
///
/// Dieser Zaun macht die kleinste, mechanisch pruefbare Haelfte davon zu
/// einem Fall: **die Bestands-Begruendung und der Bestand nennen dieselben
/// Dateien.** Damit kann eine Begruendung keinen Eintrag erfinden und
/// keinen verschweigen. Sie redet dafuer in Dateinamen, so wie der Bestand
/// zaehlt; wer ueber einen TYP in einer dieser Dateien schreibt, nennt die
/// Datei dazu.
struct StockReasonFenceTests {
    /// Die Zaeune mit begruendetem Bestand. Ein neuer traegt sich hier ein.
    nonisolated static let fences: [(file: String, stock: [String: Int])] = [
        ("ItemRouterFenceTests.swift", ItemRouterFenceTests.stock),
        ("OnlineValueFenceTests.swift", OnlineValueFenceTests.stock),
    ]

    /// Jeder Dateiname, der in einer KOMMENTARZEILE steht.
    static func namedFiles(inComments text: String) -> Set<String> {
        var out: Set<String> = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("//") else { continue }
            for token in trimmed.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == ".") }) {
                if token.hasSuffix(".swift") { out.insert(String(token)) }
            }
        }
        return out
    }

    @Test("Bestand und Begruendung nennen dieselben Dateien")
    func theReasonNamesExactlyTheStock() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for fence in Self.fences {
            let text = try String(contentsOf: root.appendingPathComponent(fence.file), encoding: .utf8)
            let named = Self.namedFiles(inComments: text)
            let keys = Set(fence.stock.keys)
            #expect(named == keys,
                    """
                    \(fence.file): die Begruendung nennt \(named.sorted()), \
                    der Bestand haelt \(keys.sorted()). Eine Begruendung, die eine \
                    Datei erfindet, wird gelesen, wenn jemand den Bestand erweitern \
                    will; eine, die eine verschweigt, laesst einen Eintrag ohne Grund
                    """)
        }
    }

    @Test("Der Pruefer sieht Dateinamen nur in Kommentaren")
    func theCheckerReadsCommentsOnly() {
        // Rot-Probe in beide Richtungen: in einem Kommentar sieht er den
        // Namen…
        #expect(Self.namedFiles(inComments: "    /// - `Foo.swift` ist die Tuer") == ["Foo.swift"])
        // …im Code nicht, denn dort steht er als Schluessel und ist damit
        // schon der Bestand selbst.
        #expect(Self.namedFiles(inComments: "        \"Foo.swift\": 1,").isEmpty)
        // Und ein Typ ohne Datei faellt durch, was genau der Fall war, der
        // diesen Zaun ausgeloest hat.
        #expect(Self.namedFiles(inComments: "    /// - `PodcastAutoDownload` ist eine Regel").isEmpty)
    }
}
#endif
