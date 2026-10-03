// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Where a kept catalogue stock lives: one file per collection, in
/// Application Support.
///
/// NOT in the defaults. Measured, the five collections are about 103 MB raw
/// and 31 MB compressed; a defaults blob is read and written whole, and the
/// day store already showed what that costs in a hot path. A file per
/// collection is read once, and a collection nobody visits costs nothing.
///
/// Derived data throughout: the lever that clears derived stores removes
/// these files too, and the app falls back to the day store and the
/// placeholder without them.
nonisolated struct CatalogStockStore: Sendable {
    static let shared = CatalogStockStore()

    /// The directory the stocks live in. Not the caches directory: the
    /// system may empty that under pressure, and a stock that vanishes
    /// mid-session would make a surface flicker between two truths.
    static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        return support.appendingPathComponent("CatalogStock", isDirectory: true)
    }

    static func fileURL(surface: String) -> URL {
        // The surface key is ours and carries no path separators, but a
        // stock file must never be able to point outside its directory.
        let safe = surface.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(safe).json")
    }

    func load(surface: String) -> CatalogStock? {
        loadDiagnosed(surface: surface).stock
    }

    /// What the file said: present and decoded, missing, or unreadable.
    /// An unreadable stock used to look exactly like "never fetched" and
    /// sent the whole collection through the network again, silently.
    func loadDiagnosed(surface: String) -> (stock: CatalogStock?, file: String) {
        let url = Self.fileURL(surface: surface)
        // Through the seam: an unreadable stock is kept aside as .corrupt
        // and logged there; the verdict names it, so the surface does not
        // read "undecodable" as "never fetched".
        switch Ablage(directory: url.deletingLastPathComponent())
            .loadNow(CatalogStock.self, name: url.lastPathComponent) {
        case .fresh: return (nil, "missing")
        case .loaded(let stock): return (stock, "present")
        case .corrupt: return (nil, "undecodable")
        }
    }

    /// Writes through a temporary file and renames. A half-written stock
    /// after a crash would decode as nothing and silently look like "never
    /// fetched", and the next run would pull the whole collection again.
    @discardableResult
    func save(_ stock: CatalogStock) -> Bool {
        // The seam writes through a temporary file and a rename, logs a
        // failure at its one place and throws it here. The stock stays
        // whatever it was; the surface keeps working through the fallback.
        let target = Self.fileURL(surface: stock.surface)
        do {
            try Ablage(directory: target.deletingLastPathComponent())
                .saveNow(stock, name: target.lastPathComponent)
            return true
        } catch {
            return false
        }
    }

    /// The collections that actually hold something, for the witnesses; no
    /// surface reads it.
    func keptSurfaces() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Removes every kept stock. Returns how many files went, so the lever
    /// can say what it emptied instead of claiming success.
    @discardableResult
    func clear() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        var gone = 0
        for file in files where file.pathExtension == "json" {
            if (try? FileManager.default.removeItem(at: file)) != nil { gone += 1 }
        }
        return gone
    }
}
