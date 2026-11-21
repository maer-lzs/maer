// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

nonisolated enum AddChapterRule {
    static let heardBelow: Double = 30
    static func next(bookId: String, chapters: [ABSChapter], position: Double, queue: [String]) -> ABSChapter? { nil }
    static func shown(_ chapter: ABSChapter, in chapters: [ABSChapter]) -> String { "" }
    static func heard(entryId: String, chapters: [ABSChapter], bookPosition: Double) -> Bool { false }
}
