// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog

/// Take a LibriVox book INTO the user's Audiobookshelf.
/// Download every section MP3 (to temp), then ONE multipart upload into the
/// chosen audiobook library. Cancellable, progress-published, errors
/// visible (rule 3), idempotent (same title already in the target library →
/// hint instead of a duplicate). Wi-Fi gate lives at the CALL site (the
/// existing cellular-warning mechanism).
@MainActor
final class LibriVoxImporter: ObservableObject {
    static let shared = LibriVoxImporter()
    private init() {}

    enum Phase: Equatable {
        case idle
        case checking
        case downloading(section: Int, of: Int)
        case uploading
        case done
        case duplicate(existingTitle: String)
        case failed(String)
    }

    /// The phase belongs to ONE book. `activeBookId` stays set
    /// through done/duplicate/failed so foreign sheets never inherit the
    /// state; a cancel resets to a clean idle (an abort is NOT an error).
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var activeBookId: String?
    private var task: Task<Void, Never>?

    /// The phase as the SHARED download ring reads it.
    /// Nil = no ring at all, a fraction = the download part n of m, and -1 =
    /// the indeterminate second phase (upload to the server; the ring keeps
    /// spinning rather than pretending to know a percentage). Terminal
    /// states (done/duplicate/failed) and idle end the animation. No frozen
    /// ring after a cancel.
    nonisolated static func ringFraction(_ phase: Phase) -> Double? {
        switch phase {
        case .checking: return -1
        case .downloading(let section, let of):
            guard of > 0 else { return -1 }
            return min(1, Double(section) / Double(of))
        case .uploading: return -1
        case .idle, .done, .duplicate, .failed: return nil
        }
    }

    /// A second import while one runs is REFUSED with a visible hint (no
    /// ghost state, no silent parallel uploads).
    var busy: Bool {
        if case .checking = phase { return true }
        if case .downloading = phase { return true }
        if case .uploading = phase { return true }
        return false
    }

    /// Audiobook libraries of the connected ABS source ([] = target 2 hidden).
    static func audiobookLibraries() async -> [ABSLibrary] {
        let libs = (try? await AppSession.shared.provider.fetchLibraries()) ?? []
        return libs.filter { ($0.mediaType ?? "book") == "book" }
    }

    func cancel() {
        task?.cancel()
        task = nil
        // Abort ⇒ neutral start state, never an error; run() sees the
        // cancellation and returns without touching the phase again.
        phase = .idle
        activeBookId = nil
    }

    /// After done/duplicate/failed at the OWN book: back to the menu (retry).
    func reset() {
        guard !busy else { return }
        phase = .idle
        activeBookId = nil
    }

    /// Recursive on-disk size of a file or directory (sweep accounting).
    nonisolated private static func itemSize(at url: URL, fm: FileManager) -> Int64 {
        var total: Int64 = 0
        if let file = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
           let size = file.totalFileAllocatedSize {
            total += Int64(size)
        }
        if let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
            for child in children { total += itemSize(at: child, fm: fm) }
        }
        return total
    }

    /// Start the import; the caller has already passed the Wi-Fi gate and
    /// picked the target library (remembered choice).
    func start(book: LibriVoxBook, itemId: String, libraryId: String, folderId: String) {
        guard !busy else { return }
        activeBookId = itemId
        phase = .checking
        task = Task { [weak self] in
            await self?.run(book: book, libraryId: libraryId, folderId: folderId)
            self?.task = nil
        }
    }

    /// Start the import into a library the user just picked. The folder is
    /// looked up here when the list did not carry it, and remembered with
    /// the library once it is known. A library without a folder, or one that
    /// cannot be reached, ends in the visible failed state with its retry,
    /// never in nothing.
    func start(book: LibriVoxBook, itemId: String, library: ABSLibrary) {
        guard !busy else { return }
        activeBookId = itemId
        phase = .checking
        task = Task { [weak self] in
            let answer = await ImportFolder.resolve(listed: library.folders) {
                try await AppSession.shared.apiClient.fetchLibraryFolders(libraryId: library.id)
            }
            guard let self, !Task.isCancelled else { return }
            switch answer {
            case .folder(let folderId):
                AppStorageKeys.set(library.id, for: AppStorageKeys.librivoxImportLibraryId)
                AppStorageKeys.set(folderId, for: AppStorageKeys.librivoxImportFolderId)
                await self.run(book: book, libraryId: library.id, folderId: folderId)
            case .none:
                Logger.library.notice("LIBRIVOX target library has no folder")
                self.phase = .failed(String(localized: "This library has no folder to import into."))
            case .unreachable:
                Logger.library.notice("LIBRIVOX folder lookup failed")
                self.phase = .failed(String(localized: "The library could not be reached. Check the server and try again."))
            }
            self.task = nil
        }
    }

    /// Orphan sweep at app start. Partial downloads and upload
    /// bodies of a KILLED import must not rot in tmp ("no invisible MB");
    /// the freed size lands in the log. Never runs while an import is live.
    nonisolated static func sweepOrphanTemp() {
        // detached because the sweep is disk work that must not inherit a caller's cancellation
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory
            guard let entries = try? fm.contentsOfDirectory(
                at: tmp, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey]) else { return }
            var freed: Int64 = 0
            for entry in entries {
                let name = entry.lastPathComponent
                guard name.hasPrefix("librivox-import-") || (name.hasPrefix("upload-") && name.hasSuffix(".body")) else { continue }
                freed += Self.itemSize(at: entry, fm: fm)
                try? fm.removeItem(at: entry)
            }
            if freed > 0 {
                Logger.library.notice("LIBRIVOX temp sweep freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file), privacy: .public)")
            }
        }
    }

    private func run(book: LibriVoxBook, libraryId: String, folderId: String) async {
        let client = AppSession.shared.apiClient
        let title = book.title ?? "LibriVox \(book.id)"
        // The sections come BEFORE the server is asked: a book without
        // downloadable audio needs no duplicate check, and the answer must
        // not wait for a server (the witness measured it against a host
        // that never answers).
        let sections = (book.sections ?? []).filter { !($0.listen_url ?? "").isEmpty }
        guard !sections.isEmpty else {
            phase = .failed(String(localized: "This book has no downloadable audio."))
            return
        }
        // Idempotenz: same title (case-folded) already in the target library?
        if let existing = try? await AppSession.shared.provider.fetchLibraryItems(libraryId: libraryId),
           let hit = existing.first(where: {
               $0.title.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
           }) {
            phase = .duplicate(existingTitle: hit.title)
            return
        }

        var files: [(filename: String, url: URL)] = []
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("librivox-import-\(book.id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for (index, section) in sections.enumerated() {
            if Task.isCancelled { return }
            phase = .downloading(section: index + 1, of: sections.count)
            guard let remote = URL(string: section.listen_url ?? "") else { continue }
            do {
                let (downloaded, _) = try await HTTP.download(from: remote, lane: .mass)
                let name = String(format: "%03d", index + 1) + "-" + (remote.lastPathComponent)
                let local = tempDir.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: local)
                try FileManager.default.moveItem(at: downloaded, to: local)
                files.append((filename: name, url: local))
            } catch {
                // A USER abort is not an error. The cancel()
                // path already reset the state; never overwrite it.
                if Task.isCancelled || error is CancellationError
                    || (error as? URLError)?.code == .cancelled { return }
                Logger.library.error("LIBRIVOX import download failed: \(String(describing: error), privacy: .public)")
                phase = .failed(String(localized: "Download failed. Check your connection and try again."))
                return
            }
        }

        if Task.isCancelled { return }
        // Send the SAME cover the app shows along with the upload
        // (hi-res via itunes:image, thumb fallback). Resolves the ABS
        // cover reservation; a failed cover never fails the import.
        let itemId = FreeCatalog.librivoxPrefix + book.id
        let coverRemote = await LibriVoxCoverLoader.uploadCover(forItemId: itemId)
        if let coverRemote {
            // The one door: the cover arrives as a file over the cover lane.
            do {
                let downloaded = try await Artwork.file(for: coverRemote)
                let local = tempDir.appendingPathComponent("cover.jpg")
                // bearable, because a missing old cover.jpg is the normal case; the move after it reports every real error
                try? FileManager.default.removeItem(at: local)
                try FileManager.default.moveItem(at: downloaded, to: local)
                files.append((filename: "cover.jpg", url: local))
            } catch {
                Logger.library.notice("LIBRIVOX import cover skipped: \(String(describing: error), privacy: .public)")
            }
        }

        if Task.isCancelled { return }
        phase = .uploading
        do {
            let pd = String(localized: "Public-domain recording from LibriVox.")
            try await client.uploadAudiobook(
                libraryId: libraryId, folderId: folderId,
                title: title,
                author: FreeCatalog.authorLine(book.authors),
                description: pd,
                files: files)
            phase = .done
        } catch {
            if Task.isCancelled || error is CancellationError
                || (error as? URLError)?.code == .cancelled { return }
            Logger.library.error("LIBRIVOX import upload failed: \(String(describing: error), privacy: .public)")
            phase = .failed(String(localized: "Upload failed. Check the server and try again."))
        }
        // ActiveBookId stays. Done/duplicate/failed belong to
        // THIS book; reset()/cancel() clears.
    }
}
