// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// A book's page asked from outside the app (a tap on a book in Spotlight,
/// `OpenAudiobookIntent`): the page opens, nothing plays. The root takes the
/// request once, when it is in front, and pushes the page on the
/// audiobooks tab.
@MainActor
enum BookPageRequest {
    static var pending: String?
    static let asked = Notification.Name("maer.bookPageRequested")

    /// Notes the page and tells a root that is already running.
    static func ask(_ itemId: String) {
        pending = itemId
        NotificationCenter.default.post(name: asked, object: nil)
    }

    /// The asked page, once.
    static func take() -> String? {
        defer { pending = nil }
        return pending
    }
}
