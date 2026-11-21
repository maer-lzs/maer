// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What a sound setting does to the audio track, as the effects sheet shows
/// it: the curve of its bands over the frequencies, and the same in words
/// for VoiceOver. The curve is the player's own chain (`SoundMath.chain`)
/// read back through `SoundMath.responseDB`, never a second drawing of it.
nonisolated enum SoundCurve {
    /// The rate the curve is read at; the bands sit far below its half.
    static let sampleRate: Double = 44_100
    static let lowest: Double = 20
    static let highest: Double = 20_000

    /// `count` frequencies from 20 Hz to 20 kHz, evenly on a log scale.
    static func frequencies(count: Int) -> [Double] {
        guard count > 1 else { return [lowest] }
        return (0..<count).map { lowest * pow(highest / lowest, Double($0) / Double(count - 1)) }
    }

    /// The change in decibels at a frequency: every band of the preset as
    /// the player's chain has it, plus the volume boost.
    static func decibels(_ setting: SoundSetting, at frequency: Double) -> Double {
        let chain = SoundMath.chain(setting.shapedPreset, sampleRate: sampleRate)
        let bands = stride(from: 0, to: chain.count, by: 5).map { Array(chain[$0..<($0 + 5)]) }
        return bands.reduce(0) { $0 + SoundMath.responseDB($1, at: frequency, sampleRate: sampleRate) }
            // The gain the filter plays, so the curve shows what is heard.
            + 20 * log10(setting.playedGain)
    }

    /// The curve at `count` frequencies.
    static func curve(_ setting: SoundSetting, count: Int) -> [Double] {
        frequencies(count: count).map { decibels(setting, at: $0) }
    }

    /// The drawn range: the deepest cut of a preset at full strength below,
    /// the highest lift at full strength plus the full boost above.
    static let floorDB: Double = -16
    static let ceilingDB: Double = 17

    /// The three parts of the sound the words name, each by its bands.
    enum Region: CaseIterable, Sendable { case bass, voice, treble }

    static func bands(of region: Region) -> Range<Int> {
        switch region {
        case .bass: 0..<2
        case .voice: 2..<4
        case .treble: 4..<5
        }
    }

    enum Change: Equatable, Sendable {
        case raised(Region)
        case lowered(Region)
        /// The volume boost in percent, above 100.
        case louder(percent: Int)
    }

    /// A band moved less than this is not worth a word.
    static let noticeableDB: Double = 2

    /// The setting in words, bass to treble, then the boost; empty when it
    /// leaves the sound as it is.
    static func changes(_ setting: SoundSetting) -> [Change] {
        let gains = setting.shapedPreset.bandGainsDB
        var said: [Change] = Region.allCases.compactMap { region in
            let strongest = gains[bands(of: region)].max { abs($0) < abs($1) } ?? 0
            guard abs(strongest) >= noticeableDB else { return nil }
            return strongest > 0 ? .raised(region) : .lowered(region)
        }
        let percent = SoundSurface.gainPercent(setting.clampedGain)
        if percent > 100 { said.append(.louder(percent: percent)) }
        return said
    }
}
