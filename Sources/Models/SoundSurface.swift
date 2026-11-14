// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What the sound surfaces show, pure: the name of a device, the summary of
/// its setting, whether the filter can reach what plays now, and the steps
/// of the gain. The player sheet and the settings pages ask these alone.
nonisolated enum SoundSurface {
    /// The port type iOS gives a CarPlay route (`AVAudioSession.Port.carAudio`).
    static let carPortType = "CarAudio"

    /// The name a device goes by: a car as "CarPlay: <its name>", every
    /// other output by the name the system gives it.
    static func deviceName(_ route: SoundRoute) -> DeviceName {
        route.portType == carPortType ? .car(route.name) : .plain(route.name)
    }

    enum DeviceName: Equatable {
        case car(String)
        case plain(String)
    }

    /// What a device's row says about its setting.
    enum Summary: Equatable {
        /// No setting of its own: it follows the default.
        case followsDefault
        /// The sound as it comes.
        case off
        /// A preset, with the gain in percent when it is raised.
        case preset(id: String, gainPercent: Int?)
    }

    static func summary(_ setting: SoundSetting?) -> Summary {
        guard let setting else { return .followsDefault }
        if setting.isOff { return .off }
        let percent = gainPercent(setting.clampedGain)
        return .preset(id: SoundPresets.preset(setting.presetID).id, gainPercent: percent == 100 ? nil : percent)
    }

    /// Why the filter cannot work on what plays now, if it cannot.
    enum Block: Equatable {
        /// A station: its stream reports no audio track the filter could hang on.
        case station
        /// A title the server converts on the fly, sent without byte ranges.
        case convertedStream
    }

    /// The block for what plays now: a station always, a title only once
    /// the filter tried it and found no audio track, or could not read them.
    static func block(isRadio: Bool, lastAttach: SoundTap.Attached?) -> Block? {
        if isRadio { return .station }
        switch lastAttach {
        case .noAudioTrack, .tracksNotRead: return .convertedStream
        default: return nil
        }
    }

    /// The gain as the slider shows it, in whole percent.
    static func gainPercent(_ gain: Double) -> Int {
        Int((min(max(gain.isFinite ? gain : 1, 1), SoundSetting.gainLimit) * 100).rounded())
    }

    /// The gain of a position of the bar in percent: in steps of five,
    /// held between 100 and the limit.
    static func gain(percent: Double) -> Double {
        let stepped = (percent.isFinite ? percent / 5 : 20).rounded() * 5
        return min(max(stepped, 100), SoundSetting.gainLimit * 100) / 100
    }

    /// Whether the player's button shows a setting at work, as the speed
    /// button does when it is not 1×.
    static func isActive(_ setting: SoundSetting) -> Bool {
        !setting.isOff
    }
}

/// The edits the sound surfaces make to the book, pure: the player sheet,
/// the default and a device's page all write through these.
nonisolated enum SoundBookEdit {
    /// The player sheet's choice: for the device the sound goes out on, or
    /// for the default when no route is known.
    static func choosing(_ setting: SoundSetting, for route: SoundRoute?, in book: SoundBook) -> SoundBook {
        guard let route else { return defaulting(setting, in: book) }
        return book.setting(setting, for: route)
    }

    /// The default for every device without a setting of its own.
    static func defaulting(_ setting: SoundSetting, in book: SoundBook) -> SoundBook {
        var book = book
        book.fallback = setting
        return book
    }

    /// A device's page: its own setting, or nil to follow the default again.
    static func choosing(_ setting: SoundSetting?, forDevice key: String, in book: SoundBook) -> SoundBook {
        var book = book
        if let index = book.devices.firstIndex(where: { $0.route.key == key }) {
            book.devices[index].setting = setting
        }
        return book
    }
}
