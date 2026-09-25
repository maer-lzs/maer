// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The three fields a person sets for all shows at once, each read
/// and written through the store its per-show value already lives in. The
/// values are the stored raw strings, so `PodcastGeneralRule` answers for
/// all three, and the show's sheet takes its choices and words from here.
@MainActor
enum PodcastGeneralField: String, CaseIterable, Identifiable {
    case newEpisodes, autoDownload, keepLatest

    var id: String { rawValue }

    /// "Keep only latest" offers these; 0 keeps every episode.
    static let episodeLimits: [Int] = [0, 5, 10, 25, 50, 100]

    var choices: [String] {
        switch self {
        case .newEpisodes: return ["all", "latest", "off"]
        case .autoDownload: return PodcastAutoDownload.Mode.allCases.map(\.rawValue)
        case .keepLatest: return Self.episodeLimits.map(String.init)
        }
    }

    var name: String {
        switch self {
        case .newEpisodes: return String(localized: "Show in New Episodes")
        case .autoDownload: return String(localized: "Auto-download")
        case .keepLatest: return String(localized: "Keep only latest")
        }
    }

    func label(_ raw: String) -> String {
        switch (self, raw) {
        case (.newEpisodes, "latest"): return String(localized: "Latest only")
        case (.newEpisodes, "off"), (.autoDownload, "off"): return String(localized: "Off")
        case (.newEpisodes, _), (.keepLatest, "0"): return String(localized: "All")
        case (.autoDownload, "newest"): return String(localized: "Newest episodes")
        case (.autoDownload, _): return String(localized: "In order (from the start)")
        case (.keepLatest, _): return raw
        }
    }

    var general: String {
        switch self {
        case .newEpisodes: return AppStorageKeys.podcastInboxModeGeneral
        case .autoDownload: return PodcastAutoDownload.generalMode.rawValue
        case .keepLatest: return String(AppStorageKeys.podcastEpisodeLimitGeneral)
        }
    }

    /// The show's own value, nil when it follows the general one.
    func stored(_ showId: String) -> String? {
        switch self {
        case .newEpisodes: return AppStorageKeys.storedPodcastInboxMode(showId)
        case .autoDownload: return PodcastAutoDownload.storedMode(showId)?.rawValue
        case .keepLatest: return AppStorageKeys.storedPodcastEpisodeLimit(showId).map(String.init)
        }
    }

    func setGeneral(_ raw: String) {
        switch self {
        case .newEpisodes: AppStorageKeys.setPodcastInboxModeGeneral(raw)
        case .autoDownload:
            PodcastAutoDownload.setGeneralMode(PodcastAutoDownload.Mode(rawValue: raw) ?? .off)
        case .keepLatest: AppStorageKeys.setPodcastEpisodeLimitGeneral(Int(raw) ?? 0)
        }
    }

    /// The show's own value. A value the show already acts on writes
    /// nothing, so opening the sheet never stamps a choice (GT-14).
    func setOwn(_ raw: String, showId: String) {
        guard raw != PodcastGeneralRule.effective(stored: stored(showId), general: general) else { return }
        switch self {
        case .newEpisodes: AppStorageKeys.setPodcastInboxMode(raw, showId: showId)
        case .autoDownload:
            PodcastAutoDownload.setMode(showId, PodcastAutoDownload.Mode(rawValue: raw) ?? .off)
        case .keepLatest: AppStorageKeys.setPodcastEpisodeLimit(Int(raw) ?? 0, showId: showId)
        }
    }

    /// The show follows the general value again.
    func clear(_ showId: String) {
        switch self {
        case .newEpisodes: AppStorageKeys.clearPodcastInboxMode(showId: showId)
        case .autoDownload: PodcastAutoDownload.clearMode(showId)
        case .keepLatest: AppStorageKeys.clearPodcastEpisodeLimit(showId: showId)
        }
    }

    func storedValues(in shows: [PodcastShow]) -> [String: String] {
        var values: [String: String] = [:]
        for show in shows { values[show.id] = stored(show.id) }
        return values
    }
}

/// Changing a value for all shows: what it asks, and what it does.
@MainActor
enum PodcastGeneralSettings {
    /// The question before a change, when there is something to say: shows
    /// with their own value, or episodes that followers will lose.
    struct Question: Identifiable {
        let field: PodcastGeneralField
        let new: String
        let own: [PodcastShow]
        /// Episodes the next refresh removes, for each answer.
        let removedKeepingOwn: Int
        let removedOverwritingAll: Int
        var id: String { "\(field.rawValue)|\(new)" }

        var message: String {
            var parts: [String] = []
            if !own.isEmpty {
                let names = own.prefix(5).map(\.title).joined(separator: ", ")
                    + (own.count > 5 ? ", …" : "")
                parts.append(String(localized: "Shows with their own setting: \(own.count) (\(names))."))
            }
            parts.append(String(localized: "New value for all: \(field.label(new))."))
            if removedKeepingOwn > 0 || removedOverwritingAll > 0 {
                parts.append(String(localized: "Episodes removed at the next refresh, downloads included: \(removedKeepingOwn)."))
                if !own.isEmpty && removedOverwritingAll != removedKeepingOwn {
                    parts.append(String(localized: "With Overwrite All: \(removedOverwritingAll)."))
                }
            }
            return parts.joined(separator: " ")
        }
    }

    /// Every show we own, once.
    static func shows() -> [PodcastShow] {
        var seen: Set<String> = []
        return PodcastShowSources.ownedShows().filter { seen.insert($0.id).inserted }
    }

    /// Nil when the change can happen without a word.
    static func question(field: PodcastGeneralField, new: String, shows: [PodcastShow]) -> Question? {
        let old = field.general
        guard new != old else { return nil }
        let stored = field.storedValues(in: shows)
        let ownIds = Set(PodcastGeneralRule.own(stored: stored, general: old))
        let own = shows.filter { ownIds.contains($0.id) }
        let removed: (PodcastGeneralRule.Answer) -> Int = { answer in
            guard field == .keepLatest else { return 0 }
            return PodcastGeneralRule.removedEpisodes(
                episodeCounts: trimmableEpisodeCounts(shows), stored: stored,
                old: old, newLimit: Int(new) ?? 0, answer: answer)
        }
        let question = Question(field: field, new: new, own: own,
                                removedKeepingOwn: removed(.keepOwn),
                                removedOverwritingAll: removed(.overwriteAll))
        guard !own.isEmpty || question.removedKeepingOwn > 0 else { return nil }
        return question
    }

    /// The episode count of each show whose episodes live on this device.
    /// A server's show keeps its episodes there, and no limit trims them.
    static func trimmableEpisodeCounts(_ shows: [PodcastShow]) -> [String: Int] {
        let serverShows = Set(PodcastShowSources.absShows().map(\.id))
        var counts: [String: Int] = [:]
        for show in shows where !serverShows.contains(show.id) { counts[show.id] = show.episodes.count }
        return counts
    }

    static func apply(field: PodcastGeneralField, new: String, answer: PodcastGeneralRule.Answer,
                      shows: [PodcastShow]) {
        let cleared = PodcastGeneralRule.cleared(stored: field.storedValues(in: shows),
                                                 old: field.general, answer: answer)
        for showId in cleared { field.clear(showId) }
        field.setGeneral(new)
    }

    /// What a show sets differently from all shows, one phrase per field.
    static func differences(of show: PodcastShow) -> [String] {
        PodcastGeneralField.allCases.compactMap { field in
            guard let own = field.stored(show.id), own != field.general else { return nil }
            return "\(field.name): \(field.label(own))"
        }
    }
}
