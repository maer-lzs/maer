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
            // The row's own play control for the measurement: the layout
            // contract can only be measured where the tile that starts IS in
            // the row being watched.
            .accessibilityIdentifier("radio-menu-play")
    }
}

/// F4-discovery: a station as a compact card for the horizontal browse rows
/// (Popular / From your region) — the shared `RadioArtwork` (Y58) over the name.
///
/// f83c442 / 99ee104: a TILE navigates on tap, always — play is the explicit
/// corner glyph. The boundary runs along the BUILD FORM, not the surface: a
/// card shows ONE state you continue, a tile is an entry in a choice you first
/// want to look at. The per-caller tap mode is gone rather than defaulted:
/// three call sites had quietly set the other behaviour, and the same tile
/// shape then meant two different things one screen apart. A switch nobody can
/// set is the only fence that cannot drift.
struct RadioStationCard: View {
    let station: RadioStation
    /// Cell-cost sweep: plain reference — actions only, no subscription.
    let playerCoordinator: PlayerCoordinator
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
            pushRadioRoute(.station(station))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                RadioArtwork(stationID: station.id,
                             faviconURL: station.faviconURL.flatMap { URL(string: $0) },
                             name: station.name, homepage: station.homepage)
                    .frame(width: width, height: width)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        // Play stays reachable in ONE tap — the corner glyph,
                        // like the podcast tiles' corner action.
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
                Text(RadioMapping.displayName(station.name))
                    .font(.caption.weight(.medium))
                    // Layout-shift/a11y: reserve both lines at the CURRENT type
                    // size — the fixed 34 pt matched two caption lines only at
                    // the default size (clipped at accessibility sizes, uneven
                    // card heights otherwise).
                    .lineLimit(2, reservesSpace: true)
                    .frame(width: width, alignment: .topLeading)
                // cb2d1ed/e9649ee: TILES carry no show line — only the "My
                // Stations" cards, the station page and the player do. The
                // line used to sit here reserved-but-empty on every tile of
                // every row, and that empty text line per row was measured as
                // part of the row-spacing finding (85a7c00: 63 pt where the
                // section spacing says 24). Removing it is the decided fix;
                // adjusting spacing constants against it would have corrected
                // a number against a state that no longer exists.
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
        // Locale-independent handle — the height fence stars two stations.
        .accessibilityIdentifier("radio-favorite-toggle")
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

/// a1077a9: "Zuletzt gespielt" is a CARD, not a tile — the Featured family
/// the other tabs' continue rows use (cover face on top, text block on the
/// card colour, radius 20). Tap plays, the info pill leads to the station
/// page. Only the Zuletzt class renders this; Häufig stays a tile, the
/// browse rows stay tiles.
struct RadioFeaturedCard: View {
    let station: RadioStation
    let playerCoordinator: PlayerCoordinator
    /// cb2d1ed: a starred station carries the glyph — without it the order of
    /// "My Stations" (preference before measured time) is unexplainable.
    var isFavorite: Bool = false
    /// Measured listening time, for the card line's second state.
    var listenedSeconds: Int = 0
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
                                            coordinator: playerCoordinator,
                                            listenedSeconds: listenedSeconds)
                    Text(RadioMapping.displayName(station.name))
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2, reservesSpace: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    HStack(spacing: 6) {
                        // 52af077 (GT R1): NO static LIVE — the badge lives in
                        // the card LINE's running state, where it is true.
                        //
                        // 5bab0ad: the star line RESERVES its height on every
                        // card. Rendered always and hidden by opacity — a
                        // conditional row made the favorite card TALLER than
                        // its neighbours, which is the same class this package
                        // closed twice already (show line on tiles, bar height
                        // per active tab): a state only some elements carry
                        // must never move the geometry.
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.9))
                            .opacity(isFavorite ? 1 : 0)
                            .accessibilityLabel(Text("Favorite"))
                            .accessibilityHidden(!isFavorite)
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
        // 5bab0ad: the height fence can only measure what it can find.
        .accessibilityIdentifier("radio-card")
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
    /// cb2d1ed/e9649ee: ONE host left — the featured card. Tiles carry no
    /// show line at all any more (the reserved-but-empty line per tile was
    /// measured as part of the row-spacing excess), so the tile host fell out
    /// WITH its callers rather than lingering as the switch nobody sets.
    ///
    /// The card still RESERVES the line's height whatever its content: a card
    /// may never take its height from the playback state — that inequality is
    /// what a person sees as "the layout shifts when I press play".
    enum Host { case featuredCard }

    let stationID: String
    let host: Host
    /// The card itself keeps the coordinator as a plain reference (cell-cost
    /// rule) — THIS leaf carries the only subscription, so the active flip
    /// and the title ticks re-render leaves, never cards.
    @ObservedObject var coordinator: PlayerCoordinator
    /// cb2d1ed: measured listening time of THIS station. Makes the line's
    /// second state possible — the same line, never a second one.
    var listenedSeconds: Int = 0

    var body: some View {
        // ONE text node, whatever the state — the content changes, the layout
        // does not. Two branches "made equally tall" are equal by coincidence:
        // measured, a reserved space and a line of real glyphs differ by 2 pt,
        // and that is enough to push a whole row down when a station starts.
        //
        // the owner named the mechanism more precisely than the symptom: "we
        // GET NEW INFO at the moment we click." The content arrives seconds
        // after the tap, so the geometry must already be final before it does.
        Line(text: text, host: host, isRunning: isRunning)
            // The measurement needs to know whether the line it is about ever
            // ARRIVED — a case that cannot observe the mechanism must say so
            // instead of passing quietly.
            .accessibilityIdentifier("radio-nowplaying-line")
    }

    /// The line's content, in the three states of `RadioMyStations.cardLine` —
    /// EMPTY in the third. Not a space: whether a lone space keeps its line box
    /// is a rendering detail, and the reservation must not depend on one.
    /// `reservesSpace` states the metric outright.
    private var text: String {
        // The coordinator's MIRROR, not `viewModel.icyDisplayLine`: this leaf
        // observes the coordinator, and a nested ObservableObject publishes to
        // its own observers only — reading through it meant the line arrived
        // without anything redrawing, so it appeared at the next unrelated
        // redraw instead. That is the "the layout shifts when I press" report.
        let line = RadioMyStations.cardLine(
            isRunning: coordinator.activeItem?.id == stationID,
            runningLine: coordinator.nowPlayingLine,
            seconds: listenedSeconds)
        switch line {
        case .running(let show): return show
        case .listened(let hours): return Self.listenedLabel(hours: hours)
        case .none: return ""
        }
    }

    /// Whether THIS station is the one playing — the badge's one condition.
    private var isRunning: Bool {
        if case .running = RadioMyStations.cardLine(
            isRunning: coordinator.activeItem?.id == stationID,
            runningLine: coordinator.nowPlayingLine,
            seconds: listenedSeconds) { return true }
        return false
    }

    /// "3 Std." — the measured time, rounded down to full hours (the floor
    /// already guarantees at least one).
    private static func listenedLabel(hours: Int) -> String {
        let components = DateComponentsFormatter()
        components.unitsStyle = .abbreviated
        components.allowedUnits = [.hour]
        return components.string(from: DateComponents(hour: hours)) ?? "\(hours) h"
    }

    private struct Line: View {
        let text: String
        let host: Host

        let isRunning: Bool

        var body: some View {
            // ONE line, fixed height, whatever the state — the badge rides
            // INSIDE the line (52af077: a static LIVE outside it was a false
            // statement while an audiobook played).
            HStack(spacing: 6) {
                if isRunning { LiveBadge() }
                Text(verbatim: text)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1, reservesSpace: true)
            }
        }
    }
}

/// The card row for the Zuletzt class — RadioView and Home share it.
///
/// cb2d1ed: the same row now also carries "My Stations", with the star glyph
/// and the listening time. NOT a second card class: the form already carried
/// the pill and the line machinery this row needs, and the owner's rule is that
/// the FORM carries the behaviour — a card is an offer to continue, a tile is
/// an entry in a choice.
struct RadioFeaturedCardRow: View {
    let title: String
    let stations: [RadioStation]
    let playerCoordinator: PlayerCoordinator
    /// Ids that carry the star. Empty for the plain Zuletzt row.
    var favoriteIDs: Set<String> = []
    /// Measured seconds per station id — the card line's second state.
    var seconds: [String: Int] = [:]
    /// The counted heading with its full page, when the row has one.
    var destination: RadioRoute? = nil
    /// The stock behind the preview, for the counting heading.
    var total: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let destination {
                RowHeading<RadioRoute>(title: "", verbatimTitle: title,
                                       total: total ?? stations.count,
                                       destination: destination)
            } else {
                Text(title).font(.title3).bold().padding(.horizontal)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(RowPreview.cut(stations)) { station in
                        RadioFeaturedCard(station: station,
                                          playerCoordinator: playerCoordinator,
                                          isFavorite: favoriteIDs.contains(station.id),
                                          listenedSeconds: seconds[station.id] ?? 0)
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
                    // e77e0b1 side finding: with an EMPTY LabeledContent value
                    // the button flattened to a bare StaticText in the a11y
                    // tree and lost its identifier — combine keeps it a button.
                    .accessibilityElement(children: .combine)
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
