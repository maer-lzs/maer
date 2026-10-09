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

    /// Where an unreadable document lies aside (`CorruptStore.preserve`).
    nonisolated func asideURL(for name: String) -> URL {
        url(for: name).appendingPathExtension("corrupt")
    }

    /// No document, but its unreadable file lies aside: the name is still
    /// unreadable, not "none yet". The file aside is the sign that outlives
    /// the process; nothing readable was saved since, or the document
    /// would be there.
    private nonisolated func liesAside(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: asideURL(for: name).path)
    }

    /// What a load answers as `.corrupt` without the process having met the
    /// name: a document that is there and cannot be read (its rights, a
    /// folder in its place) or does not decode as `type`, or no document and
    /// its file aside lies there.
    private nonisolated func readsAsUnreadable<T>(_ name: String, as type: T.Type) -> Bool {
        let target = url(for: name)
        guard FileManager.default.fileExists(atPath: target.path) else { return liesAside(name) }
        // bearable, because a document that does not read is exactly the answer asked for
        guard let data = try? Data(contentsOf: target) else { return true }
        guard let decodable = type as? any Decodable.Type else { return false }
        return !Self.decodes(decodable, data)
    }

    private nonisolated static func decodes<D: Decodable>(_ type: D.Type, _ data: Data) -> Bool {
        // bearable, because the answer asked for is only whether it decodes
        (try? JSONDecoder().decode(type, from: data)) != nil
    }

    /// Read and decode a document. Missing is `.fresh`; unreadable is
    /// `.corrupt` (file preserved aside, saves of emptiness blocked), and
    /// stays `.corrupt` on later reads, also after a restart, until a
    /// readable file, a real save or a removal.
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
            guard corruptNames.contains(name) || liesAside(name) else { return .fresh }
            corruptNames.insert(name)
            return .corrupt
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
        case .fresh: outcome = liesAside(name) ? .corrupt : .fresh
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
        // The same sign the load reads: a name met unreadable in this
        // process, a document there that does not read or decode, or, with
        // no document, a file aside that outlives it. The decode test takes
        // the type of this save: it holds as long as a store writes and
        // reads a name with one and the same type.
        if isEmpty, corruptNames.contains(name) || readsAsUnreadable(name, as: T.self) {
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

    /// Remove a document. Its unreadable file aside, if any, stays for
    /// forensics under `.corrupt.removed`: after a removal the name is "none
    /// yet", and the file aside would otherwise say "unreadable" for ever.
    func remove(name: String) async throws {
        await flush(name)
        let target = url(for: name)
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try retireAside(name)
        } catch {
            Logger.library.error("ABLAGE remove failed name=\(name, privacy: .public) reason=\(String(describing: error), privacy: .public)")
            throw AblageError.write(name: name, reason: String(describing: error))
        }
        corruptNames.remove(name)
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

    /// How many bytes a grown file holds, without reading it; 0 when it is
    /// not there.
    nonisolated func grownCount(name: String) -> Int {
        let size = (try? FileManager.default.attributesOfItem(atPath: url(for: name).path))?[.size] as? NSNumber
        return size?.intValue ?? 0
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

    /// Removes a grown file; a missing one is already the goal. Its file
    /// aside goes with it, so the synchronous readers (`loadNow`, which ask
    /// the file aside) read the name as none yet, not as unreadable.
    nonisolated func removeNow(name: String) {
        // bearable, because a missing file already is the goal
        try? FileManager.default.removeItem(at: url(for: name))
        do {
            try retireAside(name)
        } catch {
            Logger.library.error("ABLAGE aside not retired name=\(name, privacy: .public) reason=\(String(describing: error), privacy: .public)")
        }
    }

    /// The file aside of a name moves to `.corrupt.removed` (an older one
    /// there is replaced): kept for forensics, no longer the sign that the
    /// name is unreadable. The one way a removal retires it.
    nonisolated func retireAside(_ name: String) throws {
        guard liesAside(name) else { return }
        let retired = asideURL(for: name).appendingPathExtension("removed")
        if FileManager.default.fileExists(atPath: retired.path) {
            try FileManager.default.removeItem(at: retired)
        }
        try FileManager.default.moveItem(at: asideURL(for: name), to: retired)
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
