// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The curve of the effects sheet: what each setting does to the audio
/// track, from the player's own chain, and the same in words.
struct SoundCurveTests {
    static func setting(_ preset: String, percent: Double = 100) -> SoundSetting {
        SoundSetting(presetID: preset, gain: SoundSurface.gain(percent: percent))
    }

    @Test("Original is flat, the boost lifts the whole curve by its decibels, and each band shows at its centre")
    func theCurveReadsTheChain() {
        for frequency in SoundCurve.frequencies(count: 40) {
            #expect(abs(SoundCurve.decibels(Self.setting("off"), at: frequency)) < 0.001, "Original moves \(frequency) Hz")
            #expect(abs(SoundCurve.decibels(Self.setting("off", percent: 200), at: frequency) - 20 * log10(2)) < 0.001)
        }
        // At a band's centre the curve carries that band's gain, give or
        // take what the neighbouring bands add.
        for preset in SoundPresets.all where !preset.isFlat {
            for (center, gain) in zip(SoundPresets.bandCenters, preset.bandGainsDB) {
                let shown = SoundCurve.decibels(Self.setting(preset.id), at: center)
                #expect(abs(shown - gain) < 1.6, "\(preset.id) at \(center) Hz shows \(shown) dB for a band of \(gain) dB")
            }
        }
        // The extremes stay inside the drawn range.
        for preset in SoundPresets.all {
            for (gain, strength) in [(1.0, 4), (2.0, 4), (2.0, 1)] {
                let curve = SoundCurve.curve(SoundSetting(presetID: preset.id, gain: gain, strength: strength), count: 200)
                #expect(curve.allSatisfy { $0 >= SoundCurve.floorDB && $0 <= SoundCurve.ceilingDB },
                        "\(preset.id) at strength \(strength) and gain \(gain) leaves the drawing")
            }
        }
        #expect(SoundCurve.frequencies(count: 3).map { $0.rounded() } == [20, 632, 20_000])
    }

    @Test("the curve is the player's chain read back, no second formula of the bands", .needsTheSources)
    func oneFormula() throws {
        let curve = try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Models/SoundCurve.swift"), encoding: .utf8)
        #expect(curve.contains("SoundMath.chain(") && curve.contains("SoundMath.responseDB("))
        for second in ["sin(", "cos(", "pow(10"] {
            #expect(!curve.contains(second), "the curve computes the bands itself: \(second)")
        }
    }

    @Test("the setting in words: bass, voice and treble as moved, then the boost; Original says the sound is unchanged")
    func theWords() {
        #expect(SoundCurve.changes(Self.setting("speech")) == [.lowered(.bass), .raised(.voice)])
        #expect(SoundCurve.changes(Self.setting("oldRecordings")) == [.lowered(.bass), .raised(.voice), .lowered(.treble)])
        #expect(SoundCurve.changes(Self.setting("louder")) == [.raised(.bass), .raised(.treble)])
        #expect(SoundCurve.changes(Self.setting("off", percent: 140)) == [.louder(percent: 140)])
        #expect(SoundCurve.changes(Self.setting("off")).isEmpty)
        #expect(SoundCurveView.words([]) == String(localized: "Sound unchanged"))
    }

    @Test("the strength multiplies the preset's bands 1, 1.5, 2, 2.5; a setting stored without it reads as 1")
    func theStrength() throws {
        #expect(SoundSetting.strengths.map(SoundSetting.factor) == [1, 1.5, 2, 2.5])
        #expect(SoundSetting.factor(0) == 1 && SoundSetting.factor(9) == 2.5, "a strength outside the steps is held at the nearest")
        var speech = Self.setting("speech")
        #expect(speech.shapedPreset.bandGainsDB == [-4, -2, 2, 4, 1])
        speech.strength = 4
        #expect(speech.shapedPreset.bandGainsDB == [-10, -5, 5, 10, 2.5])
        // The curve follows the strength: at the voice band four steps lift about 2.5 times as much.
        let gentle = SoundCurve.decibels(Self.setting("speech"), at: 3600)
        #expect(abs(SoundCurve.decibels(speech, at: 3600) - gentle * 2.5) < 0.6)
        #expect(SoundCurve.changes(SoundSetting(presetID: "louder", gain: 1, strength: 4))
                == [.raised(.bass), .raised(.voice), .raised(.treble)], "a band lifted past the threshold at a higher strength is named")
        // Original stays flat at any strength.
        #expect(SoundSetting(presetID: "off", gain: 1, strength: 4).isOff)
        let stored = try JSONDecoder().decode(SoundSetting.self, from: Data(#"{"presetID":"speech","gain":1.2}"#.utf8))
        #expect(stored.strength == 1 && stored.presetID == "speech" && stored.gain == 1.2)
        let again = try JSONDecoder().decode(SoundSetting.self, from: JSONEncoder().encode(speech))
        #expect(again == speech)
        #expect(SoundSurface.summary(speech) == .preset(id: "speech", strength: 4, gainPercent: nil))
        #expect(SoundSurface.summary(SoundSetting(presetID: "off", gain: 1.4, strength: 3)) == .preset(id: "off", strength: nil, gainPercent: 140))
    }

    @Test("the player's chain and the curve both run the preset at its strength", .needsTheSources)
    func bothRunTheStrength() throws {
        let tap = try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Models/SoundTap.swift"), encoding: .utf8)
        #expect(tap.contains("let preset = setting.shapedPreset"), "the player plays the preset without its strength")
        let curve = try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Models/SoundCurve.swift"), encoding: .utf8)
        #expect(curve.contains("SoundMath.chain(setting.shapedPreset,") && curve.contains("setting.shapedPreset.bandGainsDB"),
                "the curve draws the preset without its strength")
    }

    @Test("the flat position is called Original, the sheet shows the curve, and the sleep timer is its symbol at the accessibility sizes",
          .needsTheSources)
    func theSurfaces() throws {
        func read(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let views = try read("Sources/Views/SoundViews.swift")
        #expect(views.contains("default: \"Original\"") && views.contains("case .off: Text(\"Original\")"),
                "the flat position is still called Off")
        #expect(views.contains("case \"speech\": \"Spoken Word\"") && views.contains("case \"louder\": \"Fuller\""),
                "the presets do not carry the names used elsewhere for these curves")
        #expect(views.contains("SoundCurveView(setting: shownSetting)"), "the choice shows no curve")
        let sheet = try #require(functionBody(of: "struct EffectsSheet: View {", in: views))
        #expect(sheet.contains(".foregroundStyle(Color.primary)"), "the sheet takes the player's white for its rows")
        #expect(views.contains("SoundCurve.curve(setting, count: Self.samples)")
                && views.contains(".accessibilityValue(Text(verbatim: Self.words(SoundCurve.changes(setting))))"),
                "the drawing or its words do not come from the one curve")
        let menus = try read("Sources/Views/PlaybackMenus.swift")
        #expect(menus.contains(".accessibilityLabel(Text(\"Speed \\(text)\"))"), "the rate alone has no word for VoiceOver")
        #expect(menus.contains("} else if iconOnly || dynamicTypeSize.isAccessibilitySize {"),
                "at the accessibility sizes the sleep timer's word breaks in the player's cell")
    }
}
#endif
