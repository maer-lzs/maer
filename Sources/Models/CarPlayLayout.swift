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

    /// How many templates stand on each other at most, the tab bar
    /// included: the tab bar, the `levels`, the player and the list the
    /// player opens. The system refuses a template beyond its own limit.
    static let stackLimit = 1 + levels + 2

    /// Whether one more template may be laid on a stack of `depth`.
    static func mayPush(depth: Int) -> Bool { depth < stackLimit }

    /// What showing the player does to the stack.
    enum PlayerMove: Equatable {
        /// The player is on top: nothing moves.
        case stay
        /// The player lies under something: the car goes back to it.
        case back
        /// The player is not in the stack and there is room: it is laid on.
        case push
        /// The player is not in the stack and the stack is full.
        case full
    }

    /// The player lies in the stack at most once: on top it stays, under
    /// another template the car goes back to it, and it is laid on only
    /// when it is not there and the stack has room. `playerIndex` is its
    /// place in the stack from the bottom, nil when it is not in it.
    static func playerMove(playerOnTop: Bool, playerIndex: Int?, depth: Int) -> PlayerMove {
        if playerOnTop { return .stay }
        if let playerIndex { return playerIndex == depth - 1 ? .stay : .back }
        return mayPush(depth: depth) ? .push : .full
    }

    /// Whether a cover in a row of covers carries its name: the system
    /// draws one from iOS 26 on. A list is known by its name alone, so
    /// without it lists stay rows of text.
    static var coversCarryNames: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// What a page says about rows it does not show: a fetch that failed is
    /// no empty library, so it gets a line of its own.
    enum EmptyNote: Equatable {
        case nothing
        case noAnswer
    }

    static func emptyNote(failed: Bool) -> EmptyNote {
        failed ? .noAnswer : .nothing
    }

    /// The speed in the car's player: spoken titles only, books and
    /// episodes, by the same kind the remote commands follow.
    static func playerExtras(for itemId: String?, markedForm: ProgressMark.StartedForm? = nil) -> Bool {
        guard let itemId else { return false }
        return RemoteCommandRule.kind(forItem: itemId, markedForm: markedForm) == .spoken
    }

    /// Up Next in the car's player: whenever something waits behind the
    /// title, the orders or the rest of what was started, for books,
    /// episodes and songs alike. A live stream has nothing behind it.
    static func offersUpNext(for itemId: String?, markedForm: ProgressMark.StartedForm? = nil,
                             waiting: Int) -> Bool {
        guard itemId != nil, waiting > 0 else { return false }
        return RemoteCommandRule.kind(forItem: itemId, markedForm: markedForm) != .live
    }

    /// The next speed after `rate` among `rates`, back to the first after
    /// the last; a speed between two steps goes to the next higher one.
    static func nextRate(after rate: Double, rates: [Double]) -> Double {
        guard let first = rates.first else { return rate }
        return rates.first { $0 > rate + 0.001 } ?? first
    }
}
