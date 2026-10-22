// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Whether a background download goes round in circles.
///
/// Measured on iOS 27: a server that states a length and closes the
/// connection early makes the background session start the file over from
/// the first byte, again and again with a doubling pause (1, 2, 4, 9, 18,
/// 33 s), each run ending at the same byte, until the resource limit of
/// seven days. The progress is the only sign: a run that starts from the
/// first byte writes its first chunk as all it holds (on the loopback a
/// run reports once, measured: 50000 of 100000 every time, so the total
/// alone never falls back). A run that ends at exactly the byte the best run ended
/// at is a round without gain; a run that reaches further starts the count
/// again; a run that ends earlier (a weak network) counts neither way, so
/// a slow but honest download never fails here.
nonisolated struct DownloadStall: Equatable {
    /// Rounds without gain after which the download counts as failed.
    static let limit = 3

    /// The furthest any finished run reached.
    private(set) var best: Int64 = 0
    /// The furthest the current run reached.
    private(set) var run: Int64 = 0
    private(set) var roundsWithoutGain = 0

    /// Takes one progress report (the chunk just written and all written
    /// in this run) and says whether the download has ended `limit` runs at
    /// the same byte.
    mutating func written(_ chunk: Int64, total: Int64) -> Bool {
        if chunk == total, run > 0 {
            // A new run started from the first byte: the one before ended.
            if run > best {
                best = run
                roundsWithoutGain = 0
            } else if run == best {
                roundsWithoutGain += 1
            }
        }
        run = total
        return roundsWithoutGain >= Self.limit
    }
}
