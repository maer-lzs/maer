// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Every state that stays out names why. "This device knew better" is
/// three of the four reasons; a state with nothing to take over is the
/// fourth and must never be counted as local knowledge.
struct ForeignKeepReasonTests {
    private func state(_ position: Double, finished: Bool = false, at: Double? = nil) -> ForeignListeningState {
        ForeignListeningState(feedURL: nil, episodeGUID: nil, enclosureURL: nil, episodeLink: nil,
                              episodeTitle: nil, position: position, finished: finished, stampedAt: at)
    }

    @Test("Unter einer Sekunde ohne lokalen Eintrag ist nichts zu uebernehmen, kein lokales Wissen")
    func nothingToAdoptIsNotLocalKnowledge() {
        #expect(ForeignStateMerge.verdict(local: nil, foreign: state(0.5), duration: 3600) == .keep(.nothingToAdopt))
        #expect(ForeignStateMerge.verdict(local: nil, foreign: state(0), duration: 3600) == .keep(.nothingToAdopt))
        // Rot-Probe of the old counting: the wrapper still says "keep" for
        // it, so a caller that only asks the wrapper cannot tell the reasons.
        #expect(ForeignStateMerge.adoption(local: nil, foreign: state(0.5), duration: 3600) == nil)
        // The three "knew better" reasons, each its own name.
        #expect(ForeignStateMerge.verdict(local: [3600, 1_000], foreign: state(300, at: 2_000), duration: 3600)
                == .keep(.localPlayed))
        #expect(ForeignStateMerge.verdict(local: [300, 1_000], foreign: state(900), duration: 3600)
                == .keep(.localKnown))
        #expect(ForeignStateMerge.verdict(local: [300, 5_000], foreign: state(900, at: 2_000), duration: 3600)
                == .keep(.localNewer))
        // And an adoption stays an adoption.
        guard case .adopt(let entry, let reason) = ForeignStateMerge.verdict(local: nil, foreign: state(900, at: 2_000), duration: 3600) else {
            Issue.record("a fresh device adopts a real state")
            return
        }
        #expect(entry.first == 900 && reason == .filled)
    }
}
#endif
