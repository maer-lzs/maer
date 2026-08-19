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
        // The tap OPENS the station page (owner decision e285465) — the
        // page used to be reachable only through player and context menu.
        // Play stays explicit, as its own trailing control.
        // SIBLINGS, not nesting: a play button inside the navigation
        // button's label is flattened away by accessibility — the explicit
        // control must be its own element.
        HStack(spacing: 0) {
            Button {
                pushRadioRoute(.station(station))
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
                        name: station.name, homepage: station.homepage)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(unavailable)
            .contextMenu {
                RadioPlayMenuButton(station: station, playerCoordinator: playerCoordinator)
                RadioFavoriteButton(station: station, onToggled: onFavoriteToggled)
            }
            RadioPlayButton(station: station, playerCoordinator: playerCoordinator)
                .disabled(unavailable)
        }
        .padding(.horizontal)
        }
    }
}

/// The ONE explicit play control of the station surfaces — the circular glyph
/// the podcast tiles use for their corner action, here with play semantics.
struct RadioPlayButton: View {
    let station: RadioStation
    let playerCoordinator: PlayerCoordinator

    var body: some View {
        Button {
            RadioPlay.play(station, playerCoordinator: playerCoordinator)
        } label: {
            Image(systemName: "play.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Play"))
        .accessibilityIdentifier("station-play")
    }
}

/// The same action as a context-menu entry, shared by row and card.
struct RadioPlayMenuButton: View {
    let station: RadioStation
    let playerCoordinator: PlayerCoordinator

    var body: some View {
        Button {
            RadioPlay.play(station, playerCoordinator: playerCoordinator)
        } label: { Label("Play", systemImage: "play.fill") }
    }
}

/// F4-discovery: a station as a compact card for the horizontal browse rows
/// (Popular / From your region) — the shared `RadioArtwork` (Y58) over the name.
struct RadioStationCard: View {
    /// What the CARD's tap does. The big Häufig/Zuletzt cards keep playing
    /// (they are the radio library's continue cards — owner correction
    /// b525ab9) and carry a detail pill instead; every browse surface
    /// navigates, with play as the explicit corner glyph.
    enum TapMode { case navigates, playsOnTap }

    let station: RadioStation
    /// Cell-cost sweep: plain reference — actions only, no subscription.
    let playerCoordinator: PlayerCoordinator
    var mode: TapMode = .navigates
    /// P16a: the ROW defines the metric, not the class. In a MIXED row
    /// (Start's "Recently Played": albums next to stations) the album size is
    /// the reference for Start's density — the tile takes it as a parameter
    /// instead of a second version being built.
    var width: CGFloat = RadioStationCard.width
    var onFavoriteToggled: () -> Void = {}
    @Environment(\.pushRadioRoute) private var pushRadioRoute

    /// The tile's own default metric (browse rows, the radio tab).
    static let width: CGFloat = 128

    var body: some View {
        Button {
            switch mode {
            case .navigates: pushRadioRoute(.station(station))
            case .playsOnTap: RadioPlay.play(station, playerCoordinator: playerCoordinator)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                RadioArtwork(stationID: station.id,
                             faviconURL: station.faviconURL.flatMap { URL(string: $0) },
                             name: station.name, homepage: station.homepage)
                    .frame(width: width, height: width)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        if mode == .navigates {
                            // Play stays reachable in ONE tap — the corner
                            // glyph, like the podcast tiles' corner action.
                            Button {
                                RadioPlay.play(station, playerCoordinator: playerCoordinator)
                            } label: {
                                Image(systemName: "play.fill")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(7)
                                    .background(Circle().fill(.black.opacity(0.45)))
                            }
                            .buttonStyle(.plain)
                            .padding(6)
                            .accessibilityLabel(Text("Play"))
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if mode == .playsOnTap {
                            // The continue-card pill: the way to the page,
                            // without giving up tap-to-play.
                            Button {
                                pushRadioRoute(.station(station))
                            } label: {
                                Image(systemName: "info.circle")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(7)
                                    .background(Capsule().fill(.black.opacity(0.45)))
                            }
                            .buttonStyle(.plain)
                            .padding(6)
                            .accessibilityLabel(Text("Station Details"))
                        }
                    }
                Text(RadioMapping.displayName(station.name))
                    .font(.caption.weight(.medium))
                    // Layout-shift/a11y: reserve both lines at the CURRENT type
                    // size — the fixed 34 pt matched two caption lines only at
                    // the default size (clipped at accessibility sizes, uneven
                    // card heights otherwise).
                    .lineLimit(2, reservesSpace: true)
                    .frame(width: width, alignment: .topLeading)
                // 9d22148: the ACTIVE station's tile carries its running show
                // (one extra line, only on that tile); dormant tiles show
                // nothing stale and never touch a stream for it.
                RadioCardNowPlayingLeaf(stationID: station.id,
                                        host: .tile,
                                        coordinator: playerCoordinator)
            }
        }
        .buttonStyle(.plain)
        // A shared handle for the tiles: the layout contract of a row — every
        // tile the same height, whatever is playing — can only be measured if
        // the harness can find them.
        .accessibilityIdentifier("radio-tile")
        .contextMenu {
            RadioPlayMenuButton(station: station, playerCoordinator: playerCoordinator)
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
    var mode: RadioStationCard.TapMode = .navigates
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
                                         mode: mode, onFavoriteToggled: onFavoriteToggled)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// a1077a9: "Zuletzt gespielt" is a CARD, not a tile — the Featured family
/// the other tabs' continue rows use (cover face on top, text block on the
/// card colour, radius 20). Tap plays, the info pill leads to the station
/// page. Only the Zuletzt class renders this; Häufig stays a tile, the
/// browse rows stay tiles.
struct RadioFeaturedCard: View {
    let station: RadioStation
    let playerCoordinator: PlayerCoordinator
    @Environment(\.pushRadioRoute) private var pushRadioRoute
    /// f7b7941: the card colour comes from the COVER, like BookFeaturedCard —
    /// the hash tint stays the placeholder colour until an accent is loaded
    /// (DLF Kultur was orange logo on hash-green card).
    @StateObject private var colorLoader = CoverColorLoader()

    private var tint: Color { RadioArtwork.color(for: station.id) }
    private var cardColor: Color { colorLoader.hasAccent ? colorLoader.accent : tint }
    // 48e514e (1): family metrics — the pill reserve scales with Dynamic Type
    // exactly like Book-/PodcastFeaturedCard's.
    @ScaledMetric(relativeTo: .subheadline) private var pillReserve: CGFloat = 40

    var body: some View {
        Button {
            RadioPlay.play(station, playerCoordinator: playerCoordinator)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                RadioArtwork(stationID: station.id,
                             faviconURL: station.faviconURL.flatMap { URL(string: $0) },
                             name: station.name, homepage: station.homepage,
                             cardBackground: cardColor)
                    .frame(width: CardMetrics.featuredCardWidth,
                           height: CardMetrics.featuredCardWidth)
                    .clipped()
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [.clear, cardColor],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: CardMetrics.featuredCardWidth
                                   * RadioArtwork.cardGradientShare)
                    }
                VStack(alignment: .leading, spacing: 5) {
                    // 48e514e (2): the caption line belongs to the running
                    // show (9d22148) — the raw first community tag is gone;
                    // a card without a known show carries just name + LIVE.
                    RadioCardNowPlayingLeaf(stationID: station.id,
                                            host: .featuredCard,
                                            coordinator: playerCoordinator)
                    Text(RadioMapping.displayName(station.name))
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2, reservesSpace: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    HStack {
                        LiveBadge()
                        Spacer()
                    }
                }
                .padding(14)
                .padding(.bottom, pillReserve)   // room for the overlay pill
                .frame(width: CardMetrics.featuredCardWidth, alignment: .leading)
                .background(cardColor)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        // Recompute on station AND image change: the await follows the
        // cadenced chain, so the accent lands when the two-stage artwork's
        // final image does — favicon-only stations take theirs directly.
        .task(id: station.id) {
            let url = await RadioLogoService.shared.logoURL(
                stationID: station.id, name: RadioMapping.displayName(station.name),
                homepage: station.homepage)
                ?? station.faviconURL.flatMap { URL(string: $0) }
            await colorLoader.load(from: url)
        }
        // 48e514e (1): the family's pill at the family's place — bottom-left
        // in the text zone, the SHARED CardDetailPill (a1077a9 had asked for
        // exactly this; the top-left ⓘ was the deviation).
        .overlay(alignment: .bottomLeading) {
            CardDetailPill(value: RadioRoute.station(station)).padding(12)
        }
        .contextMenu {
            RadioPlayMenuButton(station: station, playerCoordinator: playerCoordinator)
            RadioFavoriteButton(station: station)
            RadioDetailsButton(station: station, push: pushRadioRoute)
        }
    }
}

/// 9d22148: the running show on the ACTIVE station's card — the ICY title
/// the player already parses, observed in this ONE leaf so only the active
/// card re-renders on a title tick. Dormant tiles never mount it, and no
/// tile ever opens a stream for it: the catalog has no now-playing, and
/// twelve connections per row would be rude to the stations.
private struct RadioCardNowPlayingLeaf: View {
    /// Both hosts RESERVE the line's height, and only the ink differs.
    ///
    /// The tile used to reserve nothing: it grew by one line the moment its
    /// station started playing and shrank again whenever the running title was
    /// unknown. A row of tiles then changed height under the finger, and
    /// everything below it jumped — which is what a person sees as "the layout
    /// shifts when I press play". The line belongs to the tile's METRIC, not to
    /// its content: a tile may never take its height from the playback state.
    enum Host { case featuredCard, tile }

    let stationID: String
    let host: Host
    /// The card itself keeps the coordinator as a plain reference (cell-cost
    /// rule) — THIS leaf carries the only subscription, so the active flip
    /// and the title ticks re-render leaves, never cards.
    @ObservedObject var coordinator: PlayerCoordinator

    var body: some View {
        // ONE text node, whatever the state — the content changes, the layout
        // does not. Two branches "made equally tall" are equal by coincidence:
        // measured, a reserved space and a line of real glyphs differ by 2 pt,
        // and that is enough to push a whole row down when a station starts.
        Line(text: text, host: host)
    }

    /// The running title when this station is the one playing and the title is
    /// known — otherwise a space, which occupies the line without claiming
    /// anything.
    private var text: String {
        guard coordinator.activeItem?.id == stationID,
              let line = coordinator.viewModel?.icyDisplayLine else { return " " }
        return line
    }

    private struct Line: View {
        let text: String
        let host: Host

        var body: some View {
            switch host {
            case .featuredCard:
                Text(verbatim: text)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            case .tile:
                Text(verbatim: text)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // P16a: inherit the TILE's width instead of pinning the
                    // default one — the row decides the metric now.
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The card row for the Zuletzt class — RadioView and Home share it.
struct RadioFeaturedCardRow: View {
    let title: String
    let stations: [RadioStation]
    let playerCoordinator: PlayerCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3).bold().padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(RowPreview.cut(stations)) { station in
                        RadioFeaturedCard(station: station, playerCoordinator: playerCoordinator)
                    }
                }
                .padding(.horizontal)
            }
            .scrollClipDisabled()
        }
    }
}

/// The full page behind a counted browse row: the whole stock as station
/// rows — tap opens the page, play stays the explicit control (the one
/// contract everywhere).
struct RadioStationListPage: View {
    let title: String
    let stations: [RadioStation]
    let playerCoordinator: PlayerCoordinator

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(stations) { station in
                    RadioStationRow(station: station, playerCoordinator: playerCoordinator)
                    Divider().padding(.leading, 88)
                }
            }
            .padding(.top, 12)
            .bottomBarClearance()
        }
        .navigationTitle(Text(verbatim: title))
        .navigationBarTitleDisplayMode(.inline)
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
///
/// eb10440: the SAME list serves the genre pages' multi-select — one country
/// surface, one curation, one loading state. `selection` nil keeps the
/// single-choice behaviour (national/region rows, unchanged); a non-nil set
/// switches to toggling with a worldwide row on top.
struct RadioCountryPickerList: View {
    let onChoose: (_ code: String, _ name: String) -> Void
    /// Currently selected codes — nil means single choice. An EMPTY set is a
    /// real state: worldwide, deliberately chosen.
    var selection: Set<String>? = nil
    var onToggle: ((_ code: String) -> Void)? = nil
    var onWorldwide: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var countries: [(code: String, name: String, count: Int)] = []
    @State private var loadFailed = false

    private var isMultiple: Bool { selection != nil }

    var body: some View {
        List {
            if isMultiple {
                Section {
                    Button {
                        onWorldwide?()
                    } label: {
                        LabeledContent {
                            if selection?.isEmpty == true {
                                Image(systemName: "checkmark").foregroundStyle(AppTheme.accent)
                            }
                        } label: {
                            Text("Worldwide")
                        }
                    }
                    .tint(.primary)
                    .accessibilityIdentifier("radio-country-worldwide")
                } footer: {
                    Text("Genres show the stations of the selected countries. Several are allowed.")
                }
            }
            ForEach(filtered, id: \.code) { country in
                Button {
                    if isMultiple {
                        onToggle?(country.code)
                        return
                    }
                    onChoose(country.code, country.name)
                    dismiss()
                } label: {
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(verbatim: "\(country.count)")
                                .foregroundStyle(.secondary)
                            if selection?.contains(country.code) == true {
                                Image(systemName: "checkmark").foregroundStyle(AppTheme.accent)
                            }
                        }
                    } label: {
                        // Localized display; the English name is what the
                        // states endpoint needs and is what gets persisted.
                        Text(Locale.current.localizedString(forRegionCode: country.code) ?? country.name)
                    }
                }
                .tint(.primary)
                .accessibilityIdentifier("radio-country-\(country.code)")
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
        .navigationTitle(isMultiple ? Text("Countries") : Text("Change Country"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isMultiple {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("radio-country-done")
                }
            }
        }
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
