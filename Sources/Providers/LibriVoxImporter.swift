// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine
import OSLog

/// 3125a42 Ziel 1: take a LibriVox book INTO the user's Audiobookshelf —
/// download every section MP3 (to temp), then ONE multipart upload into the
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

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var activeBookId: String?
    private var task: Task<Void, Never>?

    /// Audiobook libraries of the connected ABS source ([] = target 2 hidden).
    static func audiobookLibraries() async -> [ABSLibrary] {
        let libs = (try? await AppSession.shared.provider.fetchLibraries()) ?? []
        return libs.filter { ($0.mediaType ?? "book") == "book" }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
        activeBookId = nil
    }

    /// Start the import; the caller has already passed the Wi-Fi gate and
    /// picked the target library (remembered choice).
    func start(book: LibriVoxBook, itemId: String, libraryId: String, folderId: String) {
        guard task == nil else { return }
        activeBookId = itemId
        phase = .checking
        task = Task { [weak self] in
            await self?.run(book: book, libraryId: libraryId, folderId: folderId)
            self?.task = nil
        }
    }

    private func run(book: LibriVoxBook, libraryId: String, folderId: String) async {
        let client = AppSession.shared.apiClient
        let title = book.title ?? "LibriVox \(book.id)"
        // Idempotenz: same title (case-folded) already in the target library?
        if let existing = try? await AppSession.shared.provider.fetchLibraryItems(libraryId: libraryId),
           let hit = existing.first(where: {
               $0.title.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
           }) {
            phase = .duplicate(existingTitle: hit.title)
            activeBookId = nil
            return
        }

        let sections = (book.sections ?? []).filter { !($0.listen_url ?? "").isEmpty }
        guard !sections.isEmpty else {
            phase = .failed(String(localized: "This book has no downloadable audio."))
            activeBookId = nil
            return
        }

        var files: [(filename: String, url: URL)] = []
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("librivox-import-\(book.id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for (index, section) in sections.enumerated() {
            if Task.isCancelled { phase = .idle; activeBookId = nil; return }
            phase = .downloading(section: index + 1, of: sections.count)
            guard let remote = URL(string: section.listen_url ?? "") else { continue }
            do {
                let (downloaded, _) = try await URLSession.shared.download(from: remote)
                let name = String(format: "%03d", index + 1) + "-" + (remote.lastPathComponent)
                let local = tempDir.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: local)
                try FileManager.default.moveItem(at: downloaded, to: local)
                files.append((filename: name, url: local))
            } catch {
                Logger.library.error("LIBRIVOX import download failed: \(String(describing: error), privacy: .public)")
                phase = .failed(String(localized: "Download failed. Check your connection and try again."))
                activeBookId = nil
                return
            }
        }

        if Task.isCancelled { phase = .idle; activeBookId = nil; return }
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
            Logger.library.error("LIBRIVOX import upload failed: \(String(describing: error), privacy: .public)")
            phase = .failed(String(localized: "Upload failed. Check the server and try again."))
        }
        activeBookId = nil
    }
}
