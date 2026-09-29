// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// What a save may not do: write emptiness over a file that could not be
/// read, or fail silently.
nonisolated enum AblageError: Error, Equatable {
    /// The file of this name was unreadable and lies aside as `.corrupt`.
    /// An EMPTY state must not replace it; a real, non-empty state may.
    case blockedByCorruptFile(name: String)
    case write(name: String, reason: String)
    case encode(name: String, reason: String)
}

/// The ONE seam between the app's document stores and the disk. A store
/// names its document; the seam serializes every write per name (a later
/// save always wins, an older one never lands over a newer one), writes
/// through a temporary file and a rename, throws instead of swallowing,
/// logs at this one place, and keeps an unreadable file aside as
/// `.corrupt` so no save writes emptiness over recoverable data.
///
/// JSON today, one file per name. The row backend for SQLite sits behind
/// the same seam in the next slice; which store uses which is one table in
/// `docs/components.md`.
actor Ablage {
    /// What a load found. The same three states as `CorruptStore.Outcome`,
    /// with the value Sendable so it may cross the actor boundary.
    enum Outcome<T: Sendable>: Sendable {
        case fresh
        case loaded(T)
        case corrupt

        var value: T? {
            if case .loaded(let value) = self { return value }
            return nil
        }
    }

    /// The app's Documents directory: the home of every store today.
    static let documents = Ablage(
        directory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])

    let directory: URL
    private var chains: [String: Task<Void, Never>] = [:]
    /// Names whose file was found unreadable and moved aside. Cleared by
    /// the first non-empty save (a genuine recovery) or by a reload that
    /// finds a readable file.
    private(set) var corruptNames: Set<String> = []

    init(directory: URL) {
        self.directory = directory
    }

    nonisolated func url(for name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// Read and decode a document. Missing is `.fresh`; unreadable is
    /// `.corrupt` (file preserved aside, saves of emptiness blocked).
    func load<T: Decodable & Sendable>(_ type: T.Type, name: String) async -> Outcome<T> {
        await flush(name)
        switch CorruptStore.load(type, from: url(for: name), label: "ABLAGE \(name)") {
        case .corrupt:
            corruptNames.insert(name)
            return .corrupt
        case .loaded(let value):
            corruptNames.remove(name)
            return .loaded(value)
        case .fresh:
            return .fresh
        }
    }

    /// The init-time read: a store that builds its state in `init` cannot
    /// await. Reads the file as it is on disk (no queued write of this
    /// name may be pending yet, because nothing saved before the store
    /// exists) and records a corrupt find on the actor afterwards.
    nonisolated func loadNow<T: Decodable & Sendable>(_ type: T.Type, name: String) -> Outcome<T> {
        let outcome: Outcome<T>
        switch CorruptStore.load(type, from: url(for: name), label: "ABLAGE \(name)") {
        case .corrupt: outcome = .corrupt
        case .loaded(let value): outcome = .loaded(value)
        case .fresh: outcome = .fresh
        }
        if case .corrupt = outcome {
            Task { await self.noteCorrupt(name) }
        }
        return outcome
    }

    private func noteCorrupt(_ name: String) {
        corruptNames.insert(name)
    }

    /// Queue a write. `isEmpty` says whether the value carries nothing (the
    /// caller knows its type); an empty save over a corrupt file throws
    /// instead of burying the recoverable data. Encoding and writing run
    /// off the caller's actor, in this name's chain.
    func save<T: Encodable & Sendable>(_ value: T, name: String, isEmpty: Bool = false) async throws {
        if isEmpty, corruptNames.contains(name) {
            Logger.library.error("ABLAGE save refused name=\(name, privacy: .public) reason=empty over corrupt")
            throw AblageError.blockedByCorruptFile(name: name)
        }
        let target = url(for: name)
        let previous = chains[name]
        let task = Task<Result<Void, AblageError>, Never>.detached(priority: .utility) {
            await previous?.value
            let data: Data
            do {
                data = try JSONEncoder().encode(value)
            } catch {
                return .failure(.encode(name: name, reason: String(describing: error)))
            }
            do {
                try Self.writeAtomically(data, to: target)
                return .success(())
            } catch {
                return .failure(.write(name: name, reason: String(describing: error)))
            }
        }
        chains[name] = Task { _ = await task.value }
        switch await task.value {
        case .success:
            if !isEmpty { corruptNames.remove(name) }
        case .failure(let error):
            Logger.library.error("ABLAGE save failed name=\(name, privacy: .public) reason=\(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// The synchronous write for the few stores whose callers read the
    /// file back right after writing (the sync queue, the widget
    /// snapshots): small documents, written on the caller's thread, same
    /// temp-and-rename, same log line. Never for large documents.
    nonisolated func saveNow<T: Encodable>(_ value: T, name: String) throws {
        let target = url(for: name)
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            Logger.library.error("ABLAGE save failed name=\(name, privacy: .public) reason=\(String(describing: error), privacy: .public)")
            throw AblageError.encode(name: name, reason: String(describing: error))
        }
        do {
            try Self.writeAtomically(data, to: target)
        } catch {
            Logger.library.error("ABLAGE save failed name=\(name, privacy: .public) reason=\(String(describing: error), privacy: .public)")
            throw AblageError.write(name: name, reason: String(describing: error))
        }
    }

    /// Remove a document (and nothing else: a `.corrupt` sibling stays for
    /// forensics).
    func remove(name: String) async throws {
        await flush(name)
        let target = url(for: name)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        do {
            try FileManager.default.removeItem(at: target)
        } catch {
            Logger.library.error("ABLAGE remove failed name=\(name, privacy: .public) reason=\(String(describing: error), privacy: .public)")
            throw AblageError.write(name: name, reason: String(describing: error))
        }
    }

    /// Wait for every queued write of a name (tests, teardown, a load
    /// that must see the last save).
    func flush(_ name: String) async {
        await chains[name]?.value
    }

    // MARK: - Bytes that grow piece by piece

    /// A file that GROWS: a download kept across runs, one slice appended
    /// after the other, so an interrupted run continues instead of starting
    /// over (the catalogue dump). Not a document and never decoded
    /// here; it lives in the seam so that no file of the app is written past
    /// it. nil when there is none yet.
    nonisolated func grownBytes(name: String) -> Data? {
        // bearable, because a missing or unreadable file is a run from the start, and the caller says so with held=0
        try? Data(contentsOf: url(for: name))
    }

    /// Appends at the end; the file and its folder are made when missing.
    nonisolated func append(_ bytes: Data, name: String) throws {
        let target = url(for: name)
        let manager = FileManager.default
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: target.path) {
            guard manager.createFile(atPath: target.path, contents: nil) else {
                throw AblageError.write(name: name, reason: "could not create")
            }
        }
        let handle = try FileHandle(forWritingTo: target)
        // bearable, because the bytes are already written with write(contentsOf:) or threw before
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
    }

    /// Removes a grown file; a missing one is already the goal.
    nonisolated func removeNow(name: String) {
        // bearable, because a missing file already is the goal
        try? FileManager.default.removeItem(at: url(for: name))
    }

    /// Temporary file beside the target, then a rename: a reader never
    /// sees a half-written document.
    nonisolated static func writeAtomically(_ data: Data, to target: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        if manager.fileExists(atPath: target.path) {
            _ = try manager.replaceItemAt(target, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: target)
        }
    }
}
