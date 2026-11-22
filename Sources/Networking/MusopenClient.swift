// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The transport of the Musopen catalog: one answer of the Commons API
/// at a time, through the app's retry ladder (which names the app to the
/// server). Reading the answer is `MusopenCatalog`'s.
nonisolated enum MusopenClient {
    /// A non-2xx answer, with what came: the status and the throttle header.
    struct Failure: Error {
        let status: Int
        let retryAfter: String?
    }

    static func page(_ url: URL) async throws -> MusopenCatalog.Page {
        let (data, http) = try await RequestRetryPolicy.fetch(URLRequest(url: url))
        if let status = http?.statusCode, !(200...299).contains(status) {
            throw Failure(status: status, retryAfter: http?.value(forHTTPHeaderField: "Retry-After"))
        }
        return try MusopenCatalog.page(from: data)
    }

    /// The row of the day: one answer of the main category from the day's letter.
    static func row(on date: Date, limit: Int) async throws -> MusopenCatalog.Page {
        try await page(MusopenCatalog.categoryURL(MusopenCatalog.categories[0], token: nil,
                                                  startingAt: MusopenCatalog.rowLetter(on: date), limit: limit))
    }

    /// The next answer from where the reader stands; the cursor after it is
    /// nil once the last category is read to its end.
    static func next(from cursor: MusopenCatalog.Cursor) async throws -> (page: MusopenCatalog.Page, next: MusopenCatalog.Cursor?) {
        let category = MusopenCatalog.categories[cursor.category]
        let page = try await page(MusopenCatalog.categoryURL(category, token: cursor.token))
        return (page, MusopenCatalog.cursor(after: cursor, token: page.token))
    }

    /// One recording by its page number; nil when the file is gone or no
    /// longer one of the catalog's.
    static func recording(pageId: Int) async throws -> MusopenCatalog.Recording? {
        try await page(MusopenCatalog.fileURL(pageId: pageId)).recordings.first
    }
}
