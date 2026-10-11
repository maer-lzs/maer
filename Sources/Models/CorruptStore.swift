// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The `.corrupt` pattern as ONE surface.
///
/// The danger is not the decode failure. It is what happens NEXT. `try?` turns
/// an unreadable file into an empty state, and the next save writes that empty
/// state back over the recoverable data. A reading error becomes permanent
/// loss, and nobody ever sees an error: only an empty list.
///
/// So this type answers three states instead of two, and the third one is the
/// whole point:
///
/// * `.fresh`. No file (a new install). Saving is fine.
/// * `.loaded`. Read and decoded. Saving is fine.
/// * `.corrupt`. A file was there and could NOT be read. The original is kept
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
        /// not be replaced by emptiness. But a real, non-empty state written
        /// afterwards is a genuine recovery and may pass.
        var blocksEmptySave: Bool {
            if case .corrupt = self { return true }
            return false
        }
    }

    /// Read a file, preserving an undecodable one under `.corrupt`. A file
    /// that is there and cannot be read at all (its protection class before
    /// the first unlock, its rights, a folder in its place) is no fresh
    /// start either: it answers `.corrupt`, so the empty save is refused,
    /// and stays where it is, untouched, because the cause may pass and the
    /// next read then finds it whole. Measured: an empty save over such a
    /// folder replaced it.
    static func load<T: Decodable>(_ type: T.Type, from url: URL,
                                   label: String,
                                   log: Logger = Logger.library) -> Outcome<T> {
        guard let data = try? Data(contentsOf: url) else {
            guard FileManager.default.fileExists(atPath: url.path) else { return .fresh }
            log.error("\(label, privacy: .public) unreadable — kept in place, NOT overwritten")
            return .corrupt
        }
        if let decoded = try? JSONDecoder().decode(type, from: data) {
            return .loaded(decoded)
        }
        if preserve(url: url) {
            log.error("\(label, privacy: .public) undecodable — preserved as .corrupt, NOT overwritten")
        } else {
            log.error("\(label, privacy: .public) undecodable — could not be moved aside, kept in place, NOT overwritten")
        }
        return .corrupt
    }

    /// The same for a store that lives in `UserDefaults` (no file to move.
    /// The raw data is kept under a sibling key, so it is still recoverable).
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

    /// The write rule of a store that is read, changed and written back
    /// whole: no write while a value stands under `key` that does not
    /// decode as `type`. Its reader saw nothing there, so whatever it would
    /// write (one new row, or the empty list) replaces the unreadable value
    /// for good. The value stays as it is and the refusal has its line; a
    /// cause that passes (a later build's form read by an older one) then
    /// finds it whole.
    static func mayReplace<T: Decodable>(_ type: T.Type, defaultsKey key: String,
                                         defaults: UserDefaults = .standard,
                                         label: String,
                                         log: Logger = Logger.library) -> Bool {
        guard let data = defaults.data(forKey: key) else {
            // Something other than data under the key is no fresh start either.
            guard defaults.object(forKey: key) == nil else {
                log.error("\(label, privacy: .public) holds no data, NOT written over")
                return false
            }
            return true
        }
        guard (try? JSONDecoder().decode(type, from: data)) != nil else {
            log.error("\(label, privacy: .public) undecodable, NOT written over")
            return false
        }
        return true
    }

    /// Move the unreadable file aside, replacing an older backup: the LAST
    /// failure is the interesting one, and two backups nobody can tell apart
    /// help no one. Answers whether the file now lies aside.
    @discardableResult
    static func preserve(url: URL) -> Bool {
        let backup = url.appendingPathExtension("corrupt")
        // bearable, because a missing older backup is the usual case
        try? FileManager.default.removeItem(at: backup)
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            return true
        } catch {
            return false
        }
    }

    /// The save rule in one place: an EMPTY state must not overwrite a store
    /// that could not be read. A non-empty state may. That is the user
    /// building something new, and refusing it forever would be its own defect.
    static func maySave(isEmpty: Bool, afterCorruptRead: Bool) -> Bool {
        !(isEmpty && afterCorruptRead)
    }
}
