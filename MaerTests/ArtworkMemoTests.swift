// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The one directory of remembered picture answers behind the door. The
/// two chains (feed channel picture, radio logo) used to keep their own
/// dictionaries with their own expiry rules; this pins the one rule: a
/// found answer stays until its expiry, a clean "none" counts until its
/// expiry and only under the stamp it was made under, and nothing outside
/// the door names the old keys any more.
struct ArtworkMemoTests {
    private func suite() -> (UserDefaults, String) {
        let name = "artwork-memo-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("found stays until expiry, a no counts until expiry")
    func foundAndMissingExpire() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        Artwork.Memo.remember("feed|a", value: "https://a.example/cover.jpg", until: 1_000, now: 100, defaults: defaults)
        Artwork.Memo.remember("feed|b", value: nil, until: 500, now: 100, defaults: defaults)
        #expect(Artwork.Memo.remembered("feed|a", now: 200, defaults: defaults) == .found("https://a.example/cover.jpg"))
        #expect(Artwork.Memo.remembered("feed|b", now: 200, defaults: defaults) == .missing)
        #expect(Artwork.Memo.remembered("feed|b", now: 600, defaults: defaults) == nil, "ein abgelaufenes Nein ist offen")
        #expect(Artwork.Memo.remembered("feed|a", now: 2_000, defaults: defaults) == nil)
        #expect(Artwork.Memo.remembered("feed|unknown", now: 200, defaults: defaults) == nil)
    }

    @Test("a no counts only under its stamp, a yes under any")
    func negativesCarryTheirStamp() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        Artwork.Memo.remember("radio|no", value: nil, until: nil, under: "64-48", now: 100, defaults: defaults)
        Artwork.Memo.remember("radio|yes", value: "commons:A.svg", until: nil, under: "64-48", now: 100, defaults: defaults)
        #expect(Artwork.Memo.remembered("radio|no", under: "64-48", now: 200, defaults: defaults) == .missing)
        #expect(Artwork.Memo.remembered("radio|no", under: "96-48", now: 200, defaults: defaults) == nil, "andere Schwellen, das Nein wird neu gefragt")
        #expect(Artwork.Memo.remembered("radio|yes", under: "96-48", now: 200, defaults: defaults) == .found("commons:A.svg"))
        // A never-expiring entry counts at any moment.
        #expect(Artwork.Memo.remembered("radio|yes", now: 1e12, defaults: defaults) == .found("commons:A.svg"))
    }

    @Test("Namespaces: answers and entries deliver without prefix, only their own space")
    func namespacesStayApart() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        Artwork.Memo.remember("feed|f", value: "https://f.example/c.jpg", until: nil, now: 100, defaults: defaults)
        Artwork.Memo.remember("radio|r", value: nil, until: 150, now: 100, defaults: defaults)
        Artwork.Memo.remember("radio|s", value: "https://s.example/i.png", until: nil, now: 100, defaults: defaults)
        let answers = Artwork.Memo.answers(prefix: "radio|", now: 120, defaults: defaults)
        #expect(answers == ["r": .missing, "s": .found("https://s.example/i.png")])
        #expect(Artwork.Memo.answers(prefix: "radio|", now: 200, defaults: defaults) == ["s": .found("https://s.example/i.png")])
        #expect(Artwork.Memo.entries(prefix: "feed|", defaults: defaults).keys.sorted() == ["f"])
        #expect(Artwork.Memo.entries(prefix: "radio|", defaults: defaults)["r"]?.resolvedAt == 100)
    }

    @Test("forgetting reopens the question; writing sweeps what has expired")
    func forgetAndPrune() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        Artwork.Memo.remember("radio|old", value: nil, until: 150, now: 100, defaults: defaults)
        Artwork.Memo.remember("radio|keep", value: "x", until: nil, now: 100, defaults: defaults)
        let forgotten = Artwork.Memo.forget("radio|keep", defaults: defaults)
        #expect(forgotten)
        let again = Artwork.Memo.forget("radio|keep", defaults: defaults)
        #expect(!again)
        // A write after the expiry drops the stale negative with it.
        Artwork.Memo.remember("radio|new", value: "y", until: nil, now: 200, defaults: defaults)
        #expect(Artwork.Memo.entries(prefix: "radio|", defaults: defaults).keys.sorted() == ["new"])
    }

    /// An answer that never expires grew the directory without end. Past
    /// the ceiling the oldest search goes, never the one just written.
    @Test("above the cap the oldest search goes, never the one just written")
    func theOldestGoesPastTheCeiling() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        for n in 0..<5 {
            Artwork.Memo.remember("radio|s\(n)", value: "x\(n)", until: nil, now: 100 + Double(n), ceiling: 3, defaults: defaults)
        }
        #expect(Artwork.Memo.entries(prefix: "radio|", defaults: defaults).keys.sorted() == ["s2", "s3", "s4"])
        // A rewrite of an old key makes it the newest, not a victim.
        Artwork.Memo.remember("radio|s2", value: "again", until: nil, now: 200, ceiling: 3, defaults: defaults)
        Artwork.Memo.remember("radio|s5", value: "x5", until: nil, now: 201, ceiling: 3, defaults: defaults)
        #expect(Artwork.Memo.entries(prefix: "radio|", defaults: defaults).keys.sorted() == ["s2", "s4", "s5"])
        #expect(Artwork.Memo.ceiling == 4_000)
    }

    /// The diagnosis reads what the chain stored with its age and the
    /// address the tile loads today: a Commons file at today's width, a
    /// touch icon at its address, a negative without one.
    @Test("the diagnostic reads what is stored with age and today's address")
    func theDiagnosisReadsTheStoredForm() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let stamp = RadioLogoService.gateSignature
        Artwork.Memo.remember("radio|radio:rb:commons", value: "commons:NDR Info Logo.svg", until: nil,
                              under: stamp, now: 1_000, defaults: defaults)
        Artwork.Memo.remember("radio|radio:rb:touch", value: "https://t.example/touch.png", until: nil,
                              under: stamp, now: 1_000, defaults: defaults)
        Artwork.Memo.remember("radio|radio:rb:no", value: nil, until: 1_000 + 14 * 24 * 3600,
                              under: stamp, now: 1_000, defaults: defaults)
        let urls = RadioLogoService.storedURLs(defaults: defaults)
        #expect(urls["radio:rb:commons"]?.query?.contains("width=\(RadioLogoService.commonsWidth)") == true)
        #expect(urls["radio:rb:touch"]?.absoluteString == "https://t.example/touch.png")
        #expect(urls["radio:rb:no"] == nil)
        let outcomes = RadioLogoService.storedOutcomes(defaults: defaults)
        #expect(outcomes["radio:rb:no"]?.hasLogo == false)
        #expect(outcomes["radio:rb:commons"]?.resolvedAt == 1_000)
    }

    @Test("outside the door nobody names the directory", .needsTheSources)
    func theDirectoryKeyStaysInTheDoor() throws {
        var offenders: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let name = file.lastPathComponent
            let text = try String(contentsOf: file, encoding: .utf8)
            let namesDirectory = text.contains("\"artworkMemo\"")
            // The old keys are fenced in `RetiredDocumentsFenceTests`; the
            // door alone names its own.
            if namesDirectory, name != "Artwork+Memo.swift" { offenders.append("\(name) names the directory key") }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}
#endif
