// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The words of a routine's rule, said by the device that shows it. The id
/// carries the kind; no sentence travels.
enum RoutineWords {
    static func rule(_ kind: RoutineRule.Kind) -> String {
        switch kind {
        case .newest: String(localized: "Newest episode")
        case .next(count: 1): String(localized: "Next episode")
        case .next(let count): String(localized: "Next \(count) episodes")
        }
    }

    /// What the rule answers now: the episodes it picks, or why none.
    static func answer(_ answer: RoutinePlayback.Answer) -> String {
        switch answer {
        case .play(let items):
            items.map(\.title).formatted(.list(type: .and))
        case .absent(.noEpisodes): String(localized: "The show has no episodes yet")
        case .absent(.newestHeard): String(localized: "The newest episode is heard")
        case .absent(.nothingNext): String(localized: "No unheard episode from where you stand")
        case .absent(.offline): String(localized: "Offline, and the episode is not downloaded")
        case .showUnknown: String(localized: "Unknown on this device: follow the show so the routine finds it")
        }
    }
}

/// One rule on a list page: the show's cover and title, the rule in words
/// and what it plays now. A rule that picks nothing this time stays,
/// dimmed, with its reason.
struct RoutineRuleRow: View {
    let line: RoutinePlayback.Line
    /// The snapshot names the show when this device does not know it.
    let carried: CarriedItem?
    let cover: URL?

    var body: some View {
        let plays = !line.answer.items.isEmpty
        let said = RoutineWords.answer(line.answer)
        TrackRowLabel(lead: .cover(cover, placeholder: MediaType.podcasts.systemImage),
                      title: line.show?.title ?? carried?.title ?? RoutineWords.rule(line.rule.kind),
                      artist: plays ? "\(RoutineWords.rule(line.rule.kind)): \(said)" : RoutineWords.rule(line.rule.kind),
                      unavailable: plays ? nil : said, secondLines: nil)
            .foregroundStyle(plays ? .primary : .secondary)
            .accessibilityElement(children: .combine)
    }
}
