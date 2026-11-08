// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The fields a person sets for all shows at once, each read and written
/// through the store its per-show value already lives in. The values are the
/// stored raw strings, so `PodcastGeneralRule` answers for all of them, and
/// the show's sheet takes its choices and words from here.
@MainActor
enum PodcastGeneralField: String, CaseIterable, Identifiable {
    case newEpisodes, upNext, autoDownload, direction, keepDownloaded, playedTail

    var id: String { rawValue }

    var choices: [String] {
        switch self {
        case .newEpisodes: return ["all", "latest", "off"]
        case .upNext: return UpNextAuto.Placement.allCases.map(\.rawValue)
        case .autoDownload: return ["on", "off"]
        case .direction: return PodcastAutoDownload.Direction.allCases.map(\.rawValue)
        case .keepDownloaded: return PodcastAutoDownloadRules.keepChoices.map(String.init)
        case .playedTail: return PlayedTail.choices.map { String(Int($0)) }
        }
    }

    var name: String {
        switch self {
        case .newEpisodes: return String(localized: "Show in New Episodes")
        case .upNext: return String(localized: "New Episodes to Up Next")
        case .autoDownload: return String(localized: "Auto-download")
        case .direction: return String(localized: "Direction")
        case .keepDownloaded: return String(localized: "Keep downloaded")
        // The general value is also the audiobooks' one; a book sets its own
        // on its page.
        case .playedTail: return String(localized: "Counts as played")
        }
    }

    func label(_ raw: String) -> String {
        switch (self, raw) {
        case (.newEpisodes, "latest"): return String(localized: "Latest only")
        case (.newEpisodes, "off"), (.autoDownload, "off"), (.upNext, "off"): return String(localized: "Off")
        case (.newEpisodes, _): return String(localized: "All")
        case (.upNext, "top"): return String(localized: "Top")
        case (.upNext, _): return String(localized: "Bottom")
        case (.autoDownload, _): return String(localized: "On")
        case (.direction, "newest"): return String(localized: "Newest episodes")
        case (.direction, _): return String(localized: "In order")
        case (.keepDownloaded, _): return raw
        case (.playedTail, "0"): return String(localized: "At the end")
        case (.playedTail, "30"): return String(localized: "30 s before the end")
        case (.playedTail, "120"): return String(localized: "2 min before the end")
        case (.playedTail, "300"): return String(localized: "5 min before the end")
        case (.playedTail, _): return String(localized: "1 min before the end")
        }
    }

    var general: String {
        switch self {
        case .newEpisodes: return AppStorageKeys.podcastInboxModeGeneral
        case .upNext: return UpNextAutoChoice.general().rawValue
        case .autoDownload: return PodcastAutoDownload.generalEnabled() ? "on" : "off"
        case .direction: return PodcastAutoDownload.generalDirection().rawValue
        case .keepDownloaded: return String(PodcastAutoDownload.generalKeep())
        case .playedTail: return String(Int(PlayedTail.general()))
        }
    }

    /// The show's own value, nil when it follows the general one.
    func stored(_ showId: String) -> String? {
        switch self {
        case .newEpisodes: return AppStorageKeys.storedPodcastInboxMode(showId)
        case .upNext: return UpNextAutoChoice.stored(showId)?.rawValue
        case .autoDownload: return PodcastAutoDownload.storedEnabled(showId).map { $0 ? "on" : "off" }
        case .direction: return PodcastAutoDownload.storedDirection(showId)?.rawValue
        case .keepDownloaded: return PodcastAutoDownload.storedKeep(showId).map(String.init)
        case .playedTail: return PlayedTail.stored(showId).map { String(Int($0)) }
        }
    }

    func setGeneral(_ raw: String) {
        switch self {
        case .newEpisodes: AppStorageKeys.setPodcastInboxModeGeneral(raw)
        case .upNext: UpNextAutoChoice.setGeneral(UpNextAuto.Placement(rawValue: raw) ?? .off)
        case .autoDownload: PodcastAutoDownload.setGeneralEnabled(raw == "on")
        case .direction:
            PodcastAutoDownload.setGeneralDirection(PodcastAutoDownload.Direction(rawValue: raw) ?? .newest)
        case .keepDownloaded:
            PodcastAutoDownload.setGeneralKeep(Int(raw) ?? PodcastAutoDownloadRules.keepByDefault)
        case .playedTail: PlayedTail.set(Double(raw) ?? PlayedTail.standard, ownerId: nil)
        }
    }

    /// The show's own value. A value the show already acts on writes
    /// nothing, so opening the sheet never stamps a choice.
    func setOwn(_ raw: String, showId: String) {
        guard raw != PodcastGeneralRule.effective(stored: stored(showId), general: general) else { return }
        switch self {
        case .newEpisodes: AppStorageKeys.setPodcastInboxMode(raw, showId: showId)
        case .upNext: UpNextAutoChoice.setOwn(UpNextAuto.Placement(rawValue: raw) ?? .off, showId: showId)
        case .autoDownload: PodcastAutoDownload.setEnabled(showId, raw == "on")
        case .direction:
            PodcastAutoDownload.setDirection(showId, PodcastAutoDownload.Direction(rawValue: raw) ?? .newest)
        case .keepDownloaded:
            PodcastAutoDownload.setKeep(showId, Int(raw) ?? PodcastAutoDownloadRules.keepByDefault)
        case .playedTail: PlayedTail.set(Double(raw) ?? PlayedTail.standard, ownerId: showId)
        }
    }

    /// The show follows the general value again.
    func clear(_ showId: String) {
        switch self {
        case .newEpisodes: AppStorageKeys.clearPodcastInboxMode(showId: showId)
        case .upNext: UpNextAutoChoice.clear(showId)
        case .autoDownload: PodcastAutoDownload.clearEnabled(showId)
        case .direction: PodcastAutoDownload.clearDirection(showId)
        case .keepDownloaded: PodcastAutoDownload.clearKeep(showId)
        case .playedTail: PlayedTail.set(nil, ownerId: showId)
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
    /// with their own value.
    struct Question: Identifiable {
        let field: PodcastGeneralField
        let new: String
        let own: [PodcastShow]
        var id: String { "\(field.rawValue)|\(new)" }

        var message: String {
            let names = own.prefix(5).map(\.title).joined(separator: ", ")
                + (own.count > 5 ? ", …" : "")
            return [String(localized: "Shows with their own setting: \(own.count) (\(names))."),
                    String(localized: "New value for all: \(field.label(new)).")]
                .joined(separator: " ")
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
        let ownIds = Set(PodcastGeneralRule.own(stored: field.storedValues(in: shows), general: old))
        let own = shows.filter { ownIds.contains($0.id) }
        guard !own.isEmpty else { return nil }
        return Question(field: field, new: new, own: own)
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
