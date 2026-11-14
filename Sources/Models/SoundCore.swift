// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// One preset of the sound filter: an id and the gain of each band in
/// decibels, at the centres of `SoundPresets.bandCenters`. Names and values
/// are data, so changing them changes no code.
nonisolated struct SoundPreset: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let bandGainsDB: [Double]

    /// A preset without any band moved leaves the signal as it is.
    var isFlat: Bool { bandGainsDB.allSatisfy { $0 == 0 } }
}

nonisolated enum SoundPresets {
    /// The five band centres in hertz, one peaking filter each.
    static let bandCenters: [Double] = [60, 230, 910, 3600, 14000]
    /// The width of every band.
    static let bandQ: Double = 1.0

    static let off = SoundPreset(id: "off", bandGainsDB: [0, 0, 0, 0, 0])
    static let all: [SoundPreset] = [
        off,
        // Less rumble, more of the range where consonants sit.
        SoundPreset(id: "speech", bandGainsDB: [-4, -2, 2, 4, 1]),
        // Old recordings: hum and hiss down, the voice forward.
        SoundPreset(id: "oldRecordings", bandGainsDB: [-6, 0, 2, 3, -4]),
        // A little more at both ends, the way a quiet room needs it.
        SoundPreset(id: "louder", bandGainsDB: [3, 0, 0, 1, 2]),
    ]

    /// The preset with that id; an unknown id is "off", so a stored setting
    /// from a later build never changes the sound in a way nobody chose.
    static func preset(_ id: String) -> SoundPreset {
        all.first { $0.id == id } ?? off
    }
}

/// What one output device plays with: a preset and a gain from 1 (as it
/// comes) to `gainLimit`.
nonisolated struct SoundSetting: Codable, Hashable, Sendable {
    /// The one place the gain's ceiling is set.
    static let gainLimit: Double = 2.0

    var presetID: String
    var gain: Double

    static let off = SoundSetting(presetID: SoundPresets.off.id, gain: 1)

    /// The gain held between 1 and the limit; a value that is not a number
    /// counts as 1.
    var clampedGain: Double {
        gain.isFinite ? min(max(gain, 1), Self.gainLimit) : 1
    }

    /// Nothing to do: a flat preset and no gain. The player hangs no filter
    /// in for such a setting.
    var isOff: Bool { SoundPresets.preset(presetID).isFlat && clampedGain == 1 }
}

/// An output of the audio route as the system names it.
nonisolated struct SoundRoute: Codable, Hashable, Sendable {
    /// The kind of port and its id together: one key per device.
    let key: String
    let name: String
    let portType: String

    init(portType: String, uid: String, name: String) {
        key = "\(portType)|\(uid)"
        self.name = name
        self.portType = portType
    }
}

/// A device the app has played on, with its own setting or none; without
/// one it follows the default for other devices.
nonisolated struct SoundDevice: Codable, Hashable, Sendable {
    var route: SoundRoute
    var setting: SoundSetting?
}

/// Every device the app has played on and the default for the others.
nonisolated struct SoundBook: Codable, Hashable, Sendable {
    var fallback: SoundSetting = .off
    var devices: [SoundDevice] = []

    /// The setting that applies on this route: the device's own, else the
    /// default. No route at all takes the default too.
    func setting(for route: SoundRoute?) -> SoundSetting {
        guard let route, let device = devices.first(where: { $0.route.key == route.key }) else { return fallback }
        return device.setting ?? fallback
    }

    /// The book with this route noted: a new device joins the list without
    /// a setting of its own; a known one keeps its setting and takes the
    /// name the system gives now.
    func noting(_ route: SoundRoute) -> SoundBook {
        var book = self
        if let index = book.devices.firstIndex(where: { $0.route.key == route.key }) {
            book.devices[index].route = route
        } else {
            book.devices.append(SoundDevice(route: route, setting: nil))
        }
        return book
    }

    /// The book with this device's own setting set, or cleared with nil.
    /// A device not in the list is noted first.
    func setting(_ setting: SoundSetting?, for route: SoundRoute) -> SoundBook {
        var book = noting(route)
        if let index = book.devices.firstIndex(where: { $0.route.key == route.key }) {
            book.devices[index].setting = setting
        }
        return book
    }

    /// The book without this device; it follows the default again.
    func removing(key: String) -> SoundBook {
        var book = self
        book.devices.removeAll { $0.route.key == key }
        return book
    }
}

/// Where the filter can work at all.
nonisolated enum SoundReach {
    /// Worth hanging a filter in: not a station, and a setting that does
    /// something. A station's stream reports no audio track the filter
    /// could hang on, so it is left out before it is asked.
    static func shouldTry(isRadio: Bool, setting: SoundSetting) -> Bool {
        !isRadio && !setting.isOff
    }

    /// The filter works only on an item whose asset reports an audio track:
    /// a file, or a stream the server sends with byte ranges. A stream the
    /// server converts on the fly reports none (measured on Navidrome and
    /// Jellyfin), and the title plays without the filter.
    static func filterApplies(isRadio: Bool, hasAudioTrack: Bool, setting: SoundSetting) -> Bool {
        shouldTry(isRadio: isRadio, setting: setting) && hasAudioTrack
    }
}

/// The arithmetic of the filter, pure.
nonisolated enum SoundMath {
    /// The coefficients of one peaking band, normalised to a0 = 1, in the
    /// order vDSP takes them: b0, b1, b2, a1, a2. A band at 0 dB passes the
    /// signal unchanged.
    static func peaking(center: Double, gainDB: Double, q: Double, sampleRate: Double) -> [Double] {
        let frequency = min(center, sampleRate * 0.45)
        let a = pow(10, gainDB / 40)
        let omega = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(omega) / (2 * q)
        let a0 = 1 + alpha / a
        return [(1 + alpha * a) / a0, (-2 * cos(omega)) / a0, (1 - alpha * a) / a0,
                (-2 * cos(omega)) / a0, (1 - alpha / a) / a0]
    }

    /// The coefficients of the whole chain, band after band.
    static func chain(_ preset: SoundPreset, sampleRate: Double) -> [Double] {
        zip(SoundPresets.bandCenters, preset.bandGainsDB).flatMap { center, gain in
            peaking(center: center, gainDB: gain, q: SoundPresets.bandQ, sampleRate: sampleRate)
        }
    }

    /// The gain of one band set of coefficients at a frequency, in decibels.
    static func responseDB(_ c: [Double], at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        func magnitude(_ x0: Double, _ x1: Double, _ x2: Double) -> Double {
            let real = x0 + x1 * cos(w) + x2 * cos(2 * w)
            let imaginary = -(x1 * sin(w) + x2 * sin(2 * w))
            return (real * real + imaginary * imaginary).squareRoot()
        }
        return 20 * log10(magnitude(c[0], c[1], c[2]) / magnitude(1, c[3], c[4]))
    }

    /// The highest sample the limiter lets out.
    static let ceiling: Float = 0.98
    /// Below this the limiter does nothing.
    static let knee: Float = 0.7

    /// A soft limiter: linear up to the knee, then bending towards the
    /// ceiling without ever reaching past it. A boosted peak stays below
    /// clipping instead of being cut.
    static func limited(_ x: Float) -> Float {
        let size = abs(x)
        guard size > knee else { return x }
        let room = ceiling - knee
        let bent = knee + room * Float(tanh(Double((size - knee) / room)))
        return x < 0 ? -bent : bent
    }
}
