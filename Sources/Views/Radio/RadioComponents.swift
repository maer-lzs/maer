// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import OSLog

/// F4: THE radio station row — shared by the favorites/recents lists and the
/// genre drilldown (Regel 2). Plays directly (F3: play replaces the active
/// playback, never queued); favorite toggles from the context menu. Offline the
/// row dims and carries the white status glyph, and the tap is disabled.
struct RadioStationRow: View {
    let station: RadioStation
    /// Cell-cost sweep: plain reference (actions only) — the row builds without
    /// subscriptions; the net gate resolves in the scope leaf below.
    let playerCoordinator: PlayerCoordinator
    /// Called after the favorite is toggled, so a favorites list can refresh.
    var onFavoriteToggled: () -> Void = {}
    @Environment(\.pushRadioRoute) private var pushRadioRoute

    var body: some View {
        // Live radio is a pure net gate (never "downloaded") — the ONE
        // observing leaf wraps the row so dim AND disabled stay reactive.
        MediaAvailabilityScope(itemId: station.id, isDownloadedOverride: { false }) { unavailable in
        Button {
            RadioPlay.play(station, playerCoordinator: playerCoordinator)
        } label: {
            MediaRowContent(
                coverURL: nil,
                eyebrow: station.tags.first,
                title: RadioMapping.displayName(station.name),
                titleDimmed: unavailable,
                coverDimmed: unavailable,
                offlineBadge: unavailable,
                placeholderSystemImage: "dot.radiowaves.left.and.right",
                coverOverride: RadioArtwork(
                    stationID: station.id,
                    faviconURL: station.faviconURL.flatMap { URL(string: $0) },
                    name: station.name)
            )
            .padding(.horizontal)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(unavailable)
        .contextMenu {
            RadioFavoriteButton(station: station, onToggled: onFavoriteToggled)
            RadioDetailsButton(station: station, push: pushRadioRoute)
        }
        }
    }
}

/// F4-discovery: a station as a compact card for the horizontal browse rows
/// (Popular / From your region) — the shared `RadioArtwork` (Y58) over the name.
struct RadioStationCard: View {
    let station: RadioStation
    /// Cell-cost sweep: plain reference — actions only, no subscription.
    let playerCoordinator: PlayerCoordinator
    var onFavoriteToggled: () -> Void = {}
    @Environment(\.pushRadioRoute) private var pushRadioRoute

    static let width: CGFloat = 128

    var body: some View {
        Button {
            RadioPlay.play(station, playerCoordinator: playerCoordinator)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                RadioArtwork(stationID: station.id,
                             faviconURL: station.faviconURL.flatMap { URL(string: $0) },
                             name: station.name)
                    .frame(width: Self.width, height: Self.width)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(RadioMapping.displayName(station.name))
                    .font(.caption.weight(.medium))
                    // Layout-shift/a11y: reserve both lines at the CURRENT type
                    // size — the fixed 34 pt matched two caption lines only at
                    // the default size (clipped at accessibility sizes, uneven
                    // card heights otherwise).
                    .lineLimit(2, reservesSpace: true)
                    .frame(width: Self.width, alignment: .topLeading)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            RadioFavoriteButton(station: station, onToggled: onFavoriteToggled)
            RadioDetailsButton(station: station, push: pushRadioRoute)
        }
    }
}

/// Teil 1: context-menu entry that opens the station detail page (tap still
/// plays directly — F3). Shared by the row and the card.
struct RadioDetailsButton: View {
    let station: RadioStation
    let push: @MainActor (RadioRoute) -> Void

    var body: some View {
        Button {
            push(.station(station))
        } label: {
            Label("Station Details", systemImage: "info.circle")
        }
    }
}

/// Shared add/remove-favorite menu button.
struct RadioFavoriteButton: View {
    let station: RadioStation
    var onToggled: () -> Void = {}

    var body: some View {
        Button {
            RadioStore.toggleFavorite(station)
            onToggled()
        } label: {
            Label(RadioStore.isFavorite(station.id) ? String(localized: "Remove Favorite")
                                                     : String(localized: "Add Favorite"),
                  systemImage: RadioStore.isFavorite(station.id) ? "star.slash" : "star")
        }
    }
}

/// 6b3a35d (3): the ONE live marker — red dot + LIVE. Shared by the full
/// player's live row and the drive-mode progress line (no second pattern).
struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 8, height: 8)
            Text(verbatim: "LIVE")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
        }
    }
}

enum RadioPlay {
    /// The recent-ring records centrally in `RadioProvider.fetchItemDetail`.
    @MainActor
    static func play(_ station: RadioStation, playerCoordinator: PlayerCoordinator) {
        // 86cf180 log-first: the tap line — together with the play line in
        // fetchItemDetail one glance shows a tile↔stream swap.
        Logger.library.notice("RADIO tap uuid=\(station.id, privacy: .public) name=\(station.name, privacy: .public) stream=\(station.streamURL, privacy: .public)")
        RadioProvider.shared.remember([station])   // keep catalog hits resolvable
        Task { await playerCoordinator.open(item: RadioProvider.libraryItem(for: station)) }
    }
}

/// The shared horizontal station-card row (title + RadioStationCard carousel) —
/// used by the radio tab's sections AND the Home "Radio" section (Regel 2: one
/// row component, no copies).
struct RadioCardRow: View {
    let title: String
    let stations: [RadioStation]
    /// Cell-cost sweep: plain reference — actions only, no subscription.
    let playerCoordinator: PlayerCoordinator
    var onFavoriteToggled: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3).bold().padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    // 6fcb301: the radio card rows ran UNCAPPED — part of why
                    // the cold start felt sluggish (every station a cell).
                    ForEach(RowPreview.cut(stations)) { station in
                        RadioStationCard(station: station, playerCoordinator: playerCoordinator,
                                         onFavoriteToggled: onFavoriteToggled)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// b942da6/b1ab99d: the region picker sheet — curated state list with a
/// search field (typing filters; free text without a hit selects nothing),
/// plus the "Change Country" layer (explicit country choice, cascade step a).
/// Counts render as plain numerals (no new catalog strings).
struct RadioRegionPickerSheet: View {
    let states: [RadioBrowseCuration.Curated]
    /// Localized name of the country whose states are listed (subtitle).
    let countryTitle: String?
    let onChooseRegion: (RadioBrowseCuration.Curated) -> Void
    let onChooseCountry: (_ code: String, _ name: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if let countryTitle {
                    Section {
                        NavigationLink {
                            RadioCountryPickerList(onChoose: onChooseCountry)
                        } label: {
                            Label {
                                LabeledContent { Text(countryTitle) } label: {
                                    Text("Change Country")
                                }
                            } icon: {
                                Image(systemName: "globe")
                            }
                        }
                        .accessibilityIdentifier("radio-country-change")
                    }
                }
                Section {
                    ForEach(RadioBrowseCuration.filtered(states, query: query)) { entry in
                        Button {
                            onChooseRegion(entry)
                        } label: {
                            LabeledContent {
                                Text(verbatim: "\(entry.stationCount)")
                                    .foregroundStyle(.secondary)
                            } label: {
                                Text(entry.display)
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
            .searchable(text: $query)
            .navigationTitle(Text("Choose your region"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// The country layer: all Radio Browser countries (station counts, same
/// curation rules — no hardcoded lists), searchable; choosing persists the
/// explicit country and resets the old country's region choice.
struct RadioCountryPickerList: View {
    let onChoose: (_ code: String, _ name: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var countries: [(code: String, name: String, count: Int)] = []
    @State private var loadFailed = false

    var body: some View {
        List {
            ForEach(filtered, id: \.code) { country in
                Button {
                    onChoose(country.code, country.name)
                    dismiss()
                } label: {
                    LabeledContent {
                        Text(verbatim: "\(country.count)")
                            .foregroundStyle(.secondary)
                    } label: {
                        // Localized display; the English name is what the
                        // states endpoint needs and is what gets persisted.
                        Text(Locale.current.localizedString(forRegionCode: country.code) ?? country.name)
                    }
                }
                .tint(.primary)
            }
            if countries.isEmpty {
                // Rule 3: a failed load is VISIBLE, never a silent empty list.
                if loadFailed {
                    Text("Could not load the country list. Check your connection and try again.")
                        .foregroundStyle(.secondary)
                } else {
                    HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle(Text("Change Country"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard countries.isEmpty else { return }
            let raw = (try? await RadioBrowserClient.countries()) ?? []
            let mapped = raw.compactMap { entry -> (String, String, Int)? in
                guard let code = entry.iso_3166_1, !code.isEmpty,
                      let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else { return nil }
                return (code.uppercased(), name, entry.stationcount ?? 0)
            }
            // Same rules as the states: threshold, count-desc, then name.
            let curatedList = mapped
                .filter { $0.2 >= 2 }
                .sorted { $0.2 == $1.2 ? $0.1 < $1.1 : $0.2 > $1.2 }
                .map { (code: $0.0, name: $0.1, count: $0.2) }
            countries = curatedList
            loadFailed = curatedList.isEmpty
        }
    }

    private var filtered: [(code: String, name: String, count: Int)] {
        let q = RadioBrowseCuration.mergeKey(query)
        guard !q.isEmpty else { return countries }
        return countries.filter {
            RadioBrowseCuration.mergeKey($0.name).contains(q)
                || RadioBrowseCuration.mergeKey(Locale.current.localizedString(forRegionCode: $0.code) ?? "").contains(q)
        }
    }
}
