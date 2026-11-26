// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

nonisolated enum SmartFolderSuggestion {
    struct Show: Equatable, Sendable { var key: String; var title: String; var categories: [String]?; var inFolder: Bool }
    struct Suggestion: Equatable, Sendable { var category: String; var keys: [String] }
    static let appleTopics: [String] = []
    static func suggest(_ shows: [Show]) -> [Suggestion] { [] }
    static func name(for category: String) -> String { category }
    static func showsHint(subscriptions: Int, suggestions: Int, dismissed: Bool) -> Bool { false }
}
