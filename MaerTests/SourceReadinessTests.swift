// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The sentence a source gives when it cannot be asked names the cause that
/// really holds. Measured before this existed: the test button answered
/// "Enter server, username and password" to somebody whose server, username
/// and password were all filled in, while the source's own switch was off.
struct SourceReadinessTests {
    @Test("the cause that really holds, and only that one")
    func theCauseThatReallyHolds() {
        #expect(SourceReadiness.missing(active: true, sourceEnabled: true, servesAnything: true, address: "", username: "") == .address)
        #expect(SourceReadiness.missing(active: true, sourceEnabled: true, servesAnything: true, address: "   ", username: "u") == .address,
                "eine Adresse aus Leerzeichen ist keine")
        #expect(SourceReadiness.missing(active: true, sourceEnabled: true, servesAnything: true, address: "https://s", username: "") == .account)
        // The measured case: everything filled in, only the switch is off.
        #expect(SourceReadiness.missing(active: false, sourceEnabled: false, servesAnything: true, address: "https://s", username: "u") == .switchedOff)
        #expect(SourceReadiness.missing(active: true, sourceEnabled: true, servesAnything: true, address: "https://s", username: "u") == nil)
    }

    /// **The case that triggered the fence.** `active` is COMPOSITE
    /// (source switch and tab, for some sources also „bedient sie
    /// diese Art ueberhaupt"). Whoever leaves the switch on and turns off only
    /// the tab got the sentence „der Schalter darueber ist aus" about
    /// a switch that was on.
    @Test("switch ON and area off does not name the switch")
    func theSwitchIsNotBlamedWhenOnlyTheAreaIsOff() {
        let urteil = SourceReadiness.missing(active: false, sourceEnabled: true, servesAnything: true,
                                             address: "https://s", username: "u")
        #expect(urteil == .noAreaOn)
        #expect(urteil != .switchedOff, "der eingeschaltete Schalter wird als aus gemeldet")
        // And the opposite direction stays as it was: if the switch is really
        // off, it still says so.
        #expect(SourceReadiness.missing(active: false, sourceEnabled: false, servesAnything: true,
                                        address: "https://s", username: "u") == .switchedOff)
        // The sentence then no longer names the switch either.
        #expect(SourceReadiness.noAreaOn.sentence != SourceReadiness.switchedOff.sentence)
    }

    /// **The finding from the acceptance of this case.** With Subsonic the set of
    /// served kinds can be empty (both deselected on the sources page).
    /// Then the liveness gate fails on the empty set BEFORE it asks an
    /// area, and the area sentence sent the person to switches that are
    /// all on. Here the whole chain: the real kinds, the real gate,
    /// all areas on.
    @Test("a source that serves no kind says so and does not name the areas")
    func aSourceServingNothingSaysSo() {
        let none = SourceModes(servesMusic: false, servesAudiobooks: false)
        let allTabs = Set(MediaType.allCases)
        let live = SourceLibraries.isLive(modes: none, enabled: true, enabledTabs: allTabs)
        #expect(!live, "die Vorbedingung: das Tor faellt am leeren Satz, obwohl alle Bereiche an sind")
        let urteil = SourceReadiness.missing(active: live, sourceEnabled: true, servesAnything: !none.isEmpty,
                                             address: "https://s", username: "u")
        #expect(urteil == .servesNothing)
        #expect(urteil != .noAreaOn, "der Satz schickt zu den Bereichen, die alle an sind")
        // The order of the page stays: if the switch is off, it says so,
        // and the fields come before everything.
        #expect(SourceReadiness.missing(active: false, sourceEnabled: false, servesAnything: false,
                                        address: "https://s", username: "u") == .switchedOff)
        #expect(SourceReadiness.missing(active: false, sourceEnabled: true, servesAnything: false,
                                        address: "", username: "u") == .address)
    }

    /// The order is that of the page: first what is typed in, then the
    /// switch above. A sentence that sends to the switch while the
    /// fields below are empty sends the person twice.
    @Test("the switch is named last, not first")
    func theSwitchIsNamedLast() {
        #expect(SourceReadiness.missing(active: false, sourceEnabled: false, servesAnything: true, address: "", username: "") == .address)
        #expect(SourceReadiness.missing(active: false, sourceEnabled: false, servesAnything: true, address: "https://s", username: "") == .account)
    }

    @Test("each cause has its own sentence, and none lists three things")
    func eachCauseHasItsOwnSentence() {
        let saetze = [SourceReadiness.address.sentence,
                      SourceReadiness.account.sentence,
                      SourceReadiness.switchedOff.sentence,
                      SourceReadiness.noAreaOn.sentence,
                      SourceReadiness.servesNothing.sentence]
        // Asked independent of language: the host runs German, a witness on
        // an English word would have measured the translation and not the
        // rule.
        #expect(Set(saetze).count == 5, "zwei Ursachen sagen dasselbe")
        for satz in saetze {
            #expect(satz.count > 10, "ein Satz, der nichts sagt")
            #expect(!satz.contains("server, username and password"),
                    "der alte Satz zaehlt drei Dinge auf und prueft eines")
        }
    }

    /// The fence over the CLASS: no source keeps its own
    /// readiness sentence. Both music sources had the same one word for word.
    @Test("no provider builds its own readiness sentence", .needsTheSources)
    func noProviderBuildsItsOwnReadinessSentence() throws {
        let wurzel = SourceTree.root.appendingPathComponent("Sources")
        let dateien = SourceTree.files(under: wurzel)
            .filter { $0.pathExtension == "swift" }
        try #require(dateien.count > 100, "der Zaun hat den Quellbaum nicht gelesen")
        var stellen: [String] = []
        for datei in dateien {
            let text = try String(contentsOf: datei, encoding: .utf8)
            if text.contains("Enter server, username and password") {
                stellen.append(datei.lastPathComponent)
            }
        }
        #expect(stellen.isEmpty, "der alte Sammelsatz steht wieder in \(stellen)")
    }

    /// **The fence over the CLASS of this case:** whoever names a cause must
    /// get the SINGLE value, not the composite one. The rules
    /// therefore take their switch from an `…EnabledValue`; if an `…Active`
    /// arrived there again, nobody would see it, because both are `Bool` and
    /// the difference shows only on the surface.
    @Test("no caller passes a composite value through as a switch", .needsTheSources)
    func noCallerPassesAComposedValueAsTheSwitch() throws {
        let wurzel = SourceTree.root.appendingPathComponent("Sources")
        let dateien = SourceTree.files(under: wurzel)
            .filter { $0.pathExtension == "swift" }
        try #require(dateien.count > 100, "der Zaun hat den Quellbaum nicht gelesen")
        var stellen: [String] = []
        for datei in dateien {
            let text = try String(contentsOf: datei, encoding: .utf8)
            // The whitespace is COLLAPSED and the argument ends at the
            // comma: a character window would have read the next line here
            // and reported my own correct call as a violation
            // (exactly how this fence broke on the first run).
            let flach = text.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: " ")
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            for argument in ["sourceEnabled:", "sourceOn:"] {
                var rest = Substring(flach)
                while let treffer = rest.range(of: argument) {
                    let danach = rest[treffer.upperBound...]
                    let wert = danach.prefix { $0 != "," && $0 != ")" }
                    if wert.contains("Active") {
                        stellen.append("\(datei.lastPathComponent): \(argument)\(wert)")
                    }
                    rest = danach
                }
            }
        }
        #expect(stellen.isEmpty, "ein zusammengesetzter Wert steht wieder als Schalter: \(stellen)")
    }
}
#endif
