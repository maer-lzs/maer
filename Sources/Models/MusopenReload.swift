// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The end of a Musopen movement whose next movement was not read in this
/// run (a restart, a start from the history or the mini player): read the
/// catalog once, as its page does, then ask the one advance again. What
/// waits in Up Next still comes first, because the advance asks it first;
/// nothing starts over a title the listener began meanwhile; a failed read
/// ends the work as before, said in the log.
enum MusopenReload {
    enum Outcome: Equatable {
        case notNeeded, readFailed, superseded, nothingFollows
        case started(String)
    }

    @MainActor
    static func run(title: String, readToEnd: Bool, read: () async -> Bool, stillEnded: () -> Bool,
                    resolve: () -> String?, start: (String) async -> Void, log: (String) -> Void) async -> Outcome {
        guard MusopenOrder.needsReading(after: title, readToEnd: readToEnd) else { return .notNeeded }
        log("MUSOPEN reload reads the catalog after a movement")
        guard await read() else {
            log("MUSOPEN reload failed: the catalog could not be read, the work ends")
            return .readFailed
        }
        guard stillEnded() else {
            log("MUSOPEN reload superseded: another title began meanwhile")
            return .superseded
        }
        guard let next = resolve() else {
            log("MUSOPEN reload found nothing to follow, the work ends")
            return .nothingFollows
        }
        await start(next)
        return .started(next)
    }
}

/// The reading of the catalog begun with a numbered movement: a full
/// reading took 6.6 s, too long a pause at the movement's end. The start
/// of the movement begins it (the same rule `needsReading`, once per run);
/// the end waits for it, or reads itself when nothing began.
@MainActor
final class MusopenPrefetch {
    private var reading: Task<Bool, Never>?

    var isReading: Bool { reading != nil }

    func begin(title: String, readToEnd: Bool, read: @escaping @MainActor () async -> Bool) {
        guard reading == nil, MusopenOrder.needsReading(after: title, readToEnd: readToEnd) else { return }
        reading = Task { await read() }
    }

    /// The reading begun at the start, or `read` when none began.
    func result(read: () async -> Bool) async -> Bool {
        if let reading {
            let read = await reading.value
            // A failed reading may be begun again by the next movement.
            if !read { self.reading = nil }
            return read
        }
        return await read()
    }
}
