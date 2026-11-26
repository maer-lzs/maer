// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Folders suggested from the topic each show names in its own feed
/// (`itunes:category`, read with the feed, `PodcastShow.categories`): no
/// request of its own. Measured on 99 top feeds (26.11.2026): 98 name one,
/// the first is always one of Apple's 19 topics, a subtopic follows it.
nonisolated enum SmartFolderSuggestion {
    struct Show: Equatable, Sendable { var key: String; var title: String; var categories: [String]?; var inFolder: Bool }
    struct Suggestion: Equatable, Sendable { var category: String; var keys: [String] }

    /// Apple's topics, the names the feeds give (English, always).
    static let appleTopics = ["Arts", "Business", "Comedy", "Education", "Fiction", "Government", "History",
                              "Health & Fitness", "Kids & Family", "Leisure", "Music", "News",
                              "Religion & Spirituality", "Science", "Society & Culture", "Sports",
                              "Technology", "True Crime", "TV & Film"]

    /// Loose shows (in no folder) by their first topic; a suggestion from
    /// two shows on, the largest first, then by name. A show without a
    /// topic or in a folder stays out: a suggestion never moves a show.
    static func suggest(_ shows: [Show], folderNames: Set<String>) -> [Suggestion] { suggest(shows) }

    static func suggest(_ shows: [Show]) -> [Suggestion] {
        var order: [String] = []
        var keys: [String: [String]] = [:]
        for show in shows where !show.inFolder {
            guard let topic = show.categories?.first?.trimmingCharacters(in: .whitespaces), !topic.isEmpty else { continue }
            if keys[topic] == nil { order.append(topic) }
            keys[topic, default: []].append(show.key)
        }
        return order.compactMap { topic in
            guard let found = keys[topic], found.count >= 2 else { return nil }
            return Suggestion(category: topic, keys: found)
        }.sorted { a, b in
            a.keys.count != b.keys.count ? a.keys.count > b.keys.count
                : name(for: a.category).localizedStandardCompare(name(for: b.category)) == .orderedAscending
        }
    }

    /// The topic in the device's language; one outside Apple's list as given.
    static func name(for category: String) -> String {
        switch category {
        case "Arts": return String(localized: "Arts")
        case "Business": return String(localized: "Business")
        case "Comedy": return String(localized: "Comedy")
        case "Education": return String(localized: "Education")
        case "Fiction": return String(localized: "Fiction")
        case "Government": return String(localized: "Government")
        case "History": return String(localized: "History")
        case "Health & Fitness": return String(localized: "Health & Fitness")
        case "Kids & Family": return String(localized: "Kids & Family")
        case "Leisure": return String(localized: "Leisure")
        case "Music": return String(localized: "Music")
        case "News": return String(localized: "News")
        case "Religion & Spirituality": return String(localized: "Religion & Spirituality")
        case "Science": return String(localized: "Science")
        case "Society & Culture": return String(localized: "Society & Culture")
        case "Sports": return String(localized: "Sports")
        case "Technology": return String(localized: "Technology")
        case "True Crime": return String(localized: "True Crime")
        case "TV & Film": return String(localized: "TV & Film")
        default: return category
        }
    }

    /// The hint shows from eight subscriptions on, when there is something
    /// to suggest, and not after it was put away on this device.
    static func showsHint(subscriptions: Int, suggestions: Int, dismissed: Bool) -> Bool {
        subscriptions >= 8 && suggestions > 0 && !dismissed
    }
}
