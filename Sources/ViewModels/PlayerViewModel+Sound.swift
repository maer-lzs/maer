// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import AVFoundation
import os

/// The sound filter on the player: the setting follows the route, and a
/// filter hangs only where it can do something.
extension PlayerViewModel {
    /// Takes the setting of the route the sound goes out on now. With
    /// `notingRoute` a device not in the book yet joins it. When the new
    /// setting does something, the items that have no filter yet get one;
    /// a setting that does nothing leaves hung filters to pass the sound as
    /// it comes. Without `hangsQueued` only the setting moves: a queue
    /// about to be built new takes its filters item by item.
    func followSoundRoute(notingRoute: Bool, hangsQueued: Bool = true) {
        let route = SoundTap.currentRoute()
        var book = AppStorageKeys.soundBookValue
        if notingRoute, let route {
            let noted = book.noting(route)
            if noted != book {
                book = noted
                AppStorageKeys.soundBookValue = noted
                Logger.player.notice("SOUND device noted: \(route.portType, privacy: .public) \(route.name, privacy: .public)")
            }
        }
        let setting = book.setting(for: route)
        soundState.set(setting)
        guard hangsQueued, !setting.isOff, let player else { return }
        let isRadio = ItemNamespace.isRadio(item?.id ?? "")
        for queued in player.items() { hangSound(on: queued, isRadio: isRadio) }
    }

    /// Hangs the filter on one item when it is worth trying: not a
    /// station, and a setting that does something. Whether the item
    /// reports a track the filter can hang on decides the rest.
    func hangSound(on item: AVPlayerItem, isRadio: Bool) {
        let state = soundState
        guard SoundReach.shouldTry(isRadio: isRadio, setting: state.setting), item.audioMix == nil else { return }
        Task { @MainActor in
            let outcome = await SoundTap.attach(state, to: item)
            Logger.player.notice("SOUND filter \(outcome.rawValue, privacy: .public)")
        }
    }
}
