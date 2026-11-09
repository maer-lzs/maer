// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What the car shows, pure: the tabs for the sources that are set up, the
/// length of a section, the levels a tap passes through and the player's
/// extras. The car is the app's small sibling: few taps, Continue first.
nonisolated enum CarPlayLayout {
    enum Tab: String, Equatable, CaseIterable {
        case start, audiobooks, podcasts, music, radio
    }

    /// The tabs in their order, Start always first and each other tab only
    /// with its source set up. Radio is a tab of its own only while the
    /// system allows one more; otherwise its favourites stand on Start.
    /// Never more tabs than `maximumTabCount`: the tab bar refuses more.
    static func tabs(audiobooks: Bool, podcasts: Bool, music: Bool, radio: Bool,
                     maximumTabCount: Int) -> (tabs: [Tab], radioOnStart: Bool) {
        var tabs: [Tab] = [.start]
        if audiobooks { tabs.append(.audiobooks) }
        if podcasts { tabs.append(.podcasts) }
        if music { tabs.append(.music) }
        let radioTab = radio && tabs.count < maximumTabCount
        if radioTab { tabs.append(.radio) }
        return (Array(tabs.prefix(max(1, maximumTabCount))), radio && !radioTab)
    }

    /// How many entries a section shows on a tab before its page.
    static let sectionLimit = 6

    /// The levels below the tab bar before the player: a list, then its
    /// content. A tap on the content plays.
    static let levels = 2

    /// Up Next and the speed in the car's player: spoken titles only, books
    /// and episodes, by the same kind the remote commands follow.
    static func playerExtras(for itemId: String?, markedForm: ProgressMark.StartedForm? = nil) -> Bool {
        guard let itemId else { return false }
        return RemoteCommandRule.kind(forItem: itemId, markedForm: markedForm) == .spoken
    }

    /// The next speed after `rate` among `rates`, back to the first after
    /// the last; a speed between two steps goes to the next higher one.
    static func nextRate(after rate: Double, rates: [Double]) -> Double {
        guard let first = rates.first else { return rate }
        return rates.first { $0 > rate + 0.001 } ?? first
    }
}
