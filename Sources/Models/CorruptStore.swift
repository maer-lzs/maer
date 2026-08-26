// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The `.corrupt` pattern as ONE surface.
///
/// The danger is not the decode failure — it is what happens NEXT. `try?` turns
/// an unreadable file into an empty state, and the next save writes that empty
/// state back over the recoverable data. A reading error becomes permanent
/// loss, and nobody ever sees an error: only an empty list.
///
/// So this type answers three states instead of two, and the third one is the
/// whole point:
///
/// * `.fresh` — no file (a new install). Saving is fine.
/// * `.loaded` — read and decoded. Saving is fine.
/// * `.corrupt` — a file was there and could NOT be read. The original is kept
///   aside as `.corrupt`, and **the caller must not overwrite with an empty
///   state**. Preserving the file only serves forensics; refusing to overwrite
///   serves the person.
nonisolated enum CorruptStore {
    enum Outcome<T> {
        case fresh
        case loaded(T)
        case corrupt

        var value: T? {
            if case .loaded(let value) = self { return value }
            return nil
        }

        /// The guard the save path asks. A store that could not be read must
        /// not be replaced by emptiness — but a real, non-empty state written
        /// afterwards is a genuine recovery and may pass.
        var blocksEmptySave: Bool {
            if case .corrupt = self { return true }
            return false
        }
    }

    /// Read a file, preserving an unreadable one under `.corrupt`.
    static func load<T: Decodable>(_ type: T.Type, from url: URL,
                                   label: String,
                                   log: Logger = Logger.library) -> Outcome<T> {
        guard let data = try? Data(contentsOf: url) else { return .fresh }
        if let decoded = try? JSONDecoder().decode(type, from: data) {
            return .loaded(decoded)
        }
        preserve(url: url)
        log.error("\(label, privacy: .public) undecodable — preserved as .corrupt, NOT overwritten")
        return .corrupt
    }

    /// The same for a store that lives in `UserDefaults` (no file to move —
    /// the raw data is kept under a sibling key, so it is still recoverable).
    static func load<T: Decodable>(_ type: T.Type, defaultsKey key: String,
                                   defaults: UserDefaults = .standard,
                                   label: String,
                                   log: Logger = Logger.library) -> Outcome<T> {
        guard let data = defaults.data(forKey: key) else { return .fresh }
        if let decoded = try? JSONDecoder().decode(type, from: data) {
            return .loaded(decoded)
        }
        defaults.set(data, forKey: key + ".corrupt")
        log.error("\(label, privacy: .public) undecodable — preserved under .corrupt, NOT overwritten")
        return .corrupt
    }

    /// Move the unreadable file aside, replacing an older backup: the LAST
    /// failure is the interesting one, and two backups nobody can tell apart
    /// help no one.
    static func preserve(url: URL) {
        let backup = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
    }

    /// The save rule in one place: an EMPTY state must not overwrite a store
    /// that could not be read. A non-empty state may — that is the user
    /// building something new, and refusing it forever would be its own defect.
    static func maySave(isEmpty: Bool, afterCorruptRead: Bool) -> Bool {
        !(isEmpty && afterCorruptRead)
    }
}
