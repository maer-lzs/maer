// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The Musopen recordings on Wikimedia Commons as a catalog.
nonisolated enum MusopenCatalog {
    static let prefix = "mso:"
    static let apiURL = URL(string: "https://commons.wikimedia.org/w/api.php")!
    static let categories: [String] = []
    static let pageSize = 0

    enum Licence: String, Codable, Sendable, CaseIterable {
        case publicDomain, cc0
        init?(stated: String?) { return nil }
        var label: String { "" }
    }

    enum Dropped: String, CaseIterable, Sendable, Error {
        case notAudio, licence, noPlayableForm
    }

    struct Recording: Codable, Sendable, Equatable {
        let pageId: Int
        let title: String
        let artistHTML: String?
        let duration: Double?
        let licence: Licence
        let audioURL: URL
        let pageURL: URL?
        var itemId: String { "" }
    }

    struct Cursor: Equatable, Sendable {
        var category: Int = 0
        var token: String? = nil
    }

    struct Page: Sendable {
        var recordings: [Recording] = []
        var dropped: [Dropped: Int] = [:]
        var token: String? = nil
    }

    static func cursor(after cursor: Cursor, token: String?) -> Cursor? { nil }

    static func pageId(of itemId: String) -> Int? { nil }

    static func categoryURL(_ category: String, token: String?, startingAt: String? = nil, limit: Int = pageSize) -> URL { apiURL }

    static func fileURL(pageId: Int) -> URL { apiURL }

    static func rowLetter(on date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String { "" }

    static func page(from data: Data) throws -> Page { Page() }

    static func shownTitle(objectName: String?, fileTitle: String?) -> String { "" }
}
