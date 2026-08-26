// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import OSLog

/// THE radio station row. Shared by the favorites/recents lists and the
/// genre drilldown. Plays directly (F3: play replaces the active
/// playback, never queued); favorite toggles from the context menu. Offline the
/// row dims and carries the white status glyph, and the tap is disabled.
struct RadioStationRow: View {
    let station: RadioStation
    /// Cell-cost sweep: plain reference (actions only). The row builds without
    /// subscriptions; the net gate resolves in the scope leaf below.
    let playerCoordinator: PlayerCoordinator
    /// Called after the favorite is toggled, so a favorites list can refresh.
    var onFavoriteToggled: () -> Void = {}
    @Environment(\.pushRadioRoute) private var pushRadioRoute

    var body: some View {
        // Live radio is a pure net gate (never "downloaded"). The ONE
        // observing leaf wraps the row so dim AND disabled stay reactive.
        MediaAvailabilityScope(itemId: station.id, isDownloadedOverride: { false }) { unavailable in
        // The tap OPENS the station page. The
        // page used to be reachable only through player and context menu.
        // Play stays explicit, as its own trailing control.
        // SIBLINGS, not nesting: a play button inside the navigation
        // button's label is flattened away by accessibility. The explicit
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

/// The ONE explicit play control of the station surfaces. The circular glyph
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
/// (Popular / From your region). The shared `RadioArtwork` (Y58) over the name.
///
/// A TILE navigates on tap, always. Play is the explicit
/// corner glyph. The boundary runs along the BUILD FORM, not the surface: a
/// card shows ONE state you continue, a tile is an entry in a choice you first
/// want to look at. The per-caller tap mode is gone rather than defaulted:
/// three call sites had quietly set the other behaviour, and the same tile
/// shape then meant two different things one screen apart. A switch nobody can
/// set is the only fence that cannot drift.
struct RadioStationCard: View {
    let station: RadioStation
    /// Cell-cost sweep: plain reference. Actions only, no subscription.
    let playerCoordinator: PlayerCoordinator
    /// A starred station carries the glyph on the TILE too. The
    /// full page renders favorites as tiles, and without the star the
    /// section order would be unexplainable there just as on the cards.
    var isFavorite: Bool = false
    /// P16a: the ROW defines the metric, not the class. In a MIXED row
    /// (Start's "Recently Played": albums next to stations) the album size is
    /// the reference for Start's density. The tile takes it as a parameter
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
                    .overlay(alignment: .topLeading) {
                        if isFavorite {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(Circle().fill(.black.opacity(0.45)))
                                .padding(6)
                                .accessibilityLabel(Text("Favorite"))
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        // Play stays reachable in ONE tap. The corner glyph,
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
                    // size. The fixed 34 pt matched two caption lines only at
                    // the default size (clipped at accessibility sizes, uneven
                    // card heights otherwise).
                    .lineLimit(2, reservesSpace: true)
                    .frame(width: width, alignment: .topLeading)
                // TILES carry no show line. Only the "My
                // Stations" cards, the station page and the player do. The
                // line used to sit here reserved-but-empty on every tile of
                // every row, and that empty text line per row was measured as
                // part of the row-spacing finding (63 pt where the section
                // spacing says 24). Adjusting spacing constants against it
                // would correct a number against a state that no longer
                // exists.
            }
        }
        .buttonStyle(.plain)
        // A shared handle for the tiles: the layout contract of a row. Every
        // tile the same height, whatever is playing. Can only be measured if
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
/// plays directly. F3). Shared by the row and the card.
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
        // Locale-independent handle. The height fence stars two stations.
        .accessibilityIdentifier("radio-favorite-toggle")
    }
}

/// The ONE live marker. Red dot + LIVE. Shared by the full
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
        // The tap line. Together with the play line in
        // fetchItemDetail one glance shows a tile↔stream swap.
        Logger.library.notice("RADIO tap uuid=\(station.id, privacy: .public) name=\(station.name, privacy: .public) stream=\(station.streamURL, privacy: .public)")
        RadioProvider.shared.remember([station])   // keep catalog hits resolvable
        Task { await playerCoordinator.open(item: RadioProvider.libraryItem(for: station)) }
    }
}

/// The shared horizontal station-card row (title + RadioStationCard carousel).
/// Used by the radio tab's sections AND the Home "Radio" section. One row
/// component, no copies.
struct RadioCardRow: View {
    let title: String
    let stations: [RadioStation]
    /// Cell-cost sweep: plain reference. Actions only, no subscription.
    let playerCoordinator: PlayerCoordinator
    var onFavoriteToggled: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3).bold().padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    // The radio card rows ran UNCAPPED. Part of why
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

/// "Zuletzt gespielt" is a CARD, not a tile. The Featured family
/// the other tabs' continue rows use (cover face on top, text block on the
/// card colour, radius 20). Tap plays, the info pill leads to the station
/// page. Only the recently-played class renders this; the most-played row
/// stays a tile, and the browse rows stay tiles.
struct RadioFeaturedCard: View {
    let station: RadioStation
    let playerCoordinator: PlayerCoordinator
    /// A starred station carries the glyph. Without it the order of
    /// "My Stations" (preference before measured time) is unexplainable.
    var isFavorite: Bool = false
    /// Measured listening time, for the card line's second state.
    var listenedSeconds: Int = 0
    @Environment(\.pushRadioRoute) private var pushRadioRoute
    /// The card colour comes from the COVER, like BookFeaturedCard.
    /// The hash tint stays the placeholder colour until an accent is loaded
    /// (DLF Kultur was orange logo on hash-green card).
    @StateObject private var colorLoader = CoverColorLoader()

    private var tint: Color { RadioArtwork.color(for: station.id) }
    /// The ground is
    /// the LOGO'S BOTTOM EDGE colour. The gradient attaches there, and a
    /// whole-image mean can never join it (measured: bigFM's edge is white,
    /// its mean lavender; WDR 2's edge is WDR-red, its mean a dark plum.
    /// Both seams were visible on device). Seamless attachment has priority;
    /// ALL ink on the card follows the ground's luminance, not just the
    /// title. White ink on bigFM's white ground would erase star and line.
    @State private var edge: RadioTileGround.Edge?
    /// Share of visible logo pixels near the edge colour. Full tone
    /// only when the edge IS the mark's dominant colour.
    @State private var dominance: Double = 1

    private var edgeIsDominant: Bool { dominance >= RadioTileGround.dominanceShare }

    /// The card's resting surface: the edge tone when it is dominant, else
    /// the calmed variant of the same tone (the accent case).
    private var cardColor: Color {
        guard let edge else { return colorLoader.hasAccent ? colorLoader.accent : tint }
        return edgeIsDominant ? edge.color : RadioTileGround.dampened(edge)
    }

    /// White ink on dark grounds, dark ink on light. Measured at the SURFACE
    /// the text sits on (the calmed area in the accent case).
    private var inkIsLight: Bool {
        guard let edge else { return true }
        let surface = edgeIsDominant ? edge.luminance : RadioTileGround.dampenedLuminance(edge)
        return RadioTileGround.titleIsLight(groundLuminance: surface)
    }
    private var titleColor: Color { inkIsLight ? .white : .black.opacity(0.85) }
    private var captionColor: Color { inkIsLight ? .white.opacity(0.9) : .black.opacity(0.6) }

    /// The seam binds to the CARD colour. Dominant edges full, accent edges
    /// DAMPENED. A zone that runs the full edge colour at the boundary while
    /// both neighbours are calm guarantees a saturated ring between two calm
    /// zones (measured: rise 1060→1220 to the full edge colour, hard fall
    /// behind); shrinking `transitionShare` only sharpens it. Now the full
    /// edge colour exists NOWHERE on a zone card. The seam stays byte-
    /// seamless, on the dampened level.
    private var textZoneGround: Color { cardColor }
    // Family metrics. The pill reserve scales with Dynamic Type
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
                        // The JOIN is the exact CARD colour (dominant: full
                        // edge, accent: dampened). The artwork already runs
                        // out into the calm tone, so no saturation peak can
                        // exist between the two calm zones.
                        LinearGradient(colors: [.clear, cardColor],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: CardMetrics.featuredCardWidth
                                   * RadioArtwork.cardGradientShare)
                    }
                VStack(alignment: .leading, spacing: 5) {
                    // The caption line belongs to the running
                    // show. The raw first community tag is gone;
                    // a card without a known show carries just name + LIVE.
                    RadioCardNowPlayingLeaf(stationID: station.id,
                                            host: .featuredCard,
                                            coordinator: playerCoordinator,
                                            listenedSeconds: listenedSeconds,
                                            ink: captionColor)
                    Text(RadioMapping.displayName(station.name))
                        .font(.headline)
                        .foregroundStyle(titleColor)
                        .lineLimit(2, reservesSpace: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    HStack(spacing: 6) {
                        // NO static LIVE. The badge lives in
                        // the card LINE's running state, where it is true.
                        //
                        // The star line RESERVES its height on every
                        // card. Rendered always and hidden by opacity. A
                        // conditional row made the favorite card TALLER than
                        // its neighbours, which is the same class this package
                        // closed twice already (show line on tiles, bar height
                        // per active tab): a state only some elements carry
                        // must never move the geometry.
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(captionColor)
                            .opacity(isFavorite ? 1 : 0)
                            .accessibilityLabel(Text("Favorite"))
                            .accessibilityHidden(!isFavorite)
                        Spacer()
                    }
                }
                .padding(14)
                .padding(.bottom, pillReserve)   // room for the overlay pill
                .frame(width: CardMetrics.featuredCardWidth, alignment: .leading)
                .background(textZoneGround)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        // The height fence can only measure what it can find.
        .accessibilityIdentifier("radio-card")
        // Recompute on station AND image change: the await follows the
        // cadenced chain, so the accent lands when the two-stage artwork's
        // final image does. Favicon-only stations take theirs directly.
        .task(id: station.id) {
            let url = await RadioLogoService.shared.logoURL(
                stationID: station.id, name: RadioMapping.displayName(station.name),
                homepage: station.homepage)
                ?? station.faviconURL.flatMap { URL(string: $0) }
            await colorLoader.load(from: url)
            // The ground colour comes from the logo's bottom edge;
            // Whether it may fill the surface depends on DOMINANCE.
            if let url, let loaded = await ImageCache.shared.loadedImage(for: url) {
                let measured = RadioTileGround.bottomEdgeColor(of: loaded.image)
                edge = measured
                if let measured {
                    dominance = RadioTileGround.dominance(of: loaded.image, edge: measured)
                }
            }
        }
        // The family's pill at the family's place. Bottom-left
        // in the text zone, the SHARED CardDetailPill. The top-left ⓘ was
        // the deviation.
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

/// The running show on the ACTIVE station's card. The ICY title
/// the player already parses, observed in this ONE leaf so only the active
/// card re-renders on a title tick. Dormant tiles never mount it, and no
/// tile ever opens a stream for it: the catalog has no now-playing, and
/// twelve connections per row would be rude to the stations.
private struct RadioCardNowPlayingLeaf: View {
    /// ONE host left. The featured card. Tiles carry no
    /// show line at all any more (the reserved-but-empty line per tile was
    /// measured as part of the row-spacing excess), so the tile host fell out
    /// WITH its callers rather than lingering as the switch nobody sets.
    ///
    /// The card still RESERVES the line's height whatever its content: a card
    /// may never take its height from the playback state. That inequality is
    /// what a person sees as "the layout shifts when I press play".
    enum Host { case featuredCard }

    let stationID: String
    let host: Host
    /// The card itself keeps the coordinator as a plain reference (cell-cost
    /// rule). THIS leaf carries the only subscription, so the active flip
    /// and the title ticks re-render leaves, never cards.
    @ObservedObject var coordinator: PlayerCoordinator
    /// Measured listening time of THIS station. Makes the line's
    /// second state possible. The same line, never a second one.
    var listenedSeconds: Int = 0
    /// The card's ink follows its ground; the leaf inherits it.
    var ink: Color = .white.opacity(0.9)

    var body: some View {
        // ONE text node, whatever the state. The content changes, the layout
        // does not. Two branches "made equally tall" are equal by coincidence:
        // measured, a reserved space and a line of real glyphs differ by 2 pt,
        // and that is enough to push a whole row down when a station starts.
        //
        // the user named the mechanism more precisely than the symptom: "we
        // GET NEW INFO at the moment we click." The content arrives seconds
        // after the tap, so the geometry must already be final before it does.
        Line(text: text, host: host, isRunning: isRunning, ink: ink)
            // The measurement needs to know whether the line it is about ever
            // ARRIVED. A case that cannot observe the mechanism must say so
            // instead of passing quietly.
            .accessibilityIdentifier("radio-nowplaying-line")
    }

    /// The line's content, in the three states of `RadioMyStations.cardLine`.
    /// EMPTY in the third. Not a space: whether a lone space keeps its line box
    /// is a rendering detail, and the reservation must not depend on one.
    /// `reservesSpace` states the metric outright.
    private var text: String {
        // The coordinator's MIRROR, not `viewModel.icyDisplayLine`: this leaf
        // observes the coordinator, and a nested ObservableObject publishes to
        // its own observers only. Reading through it meant the line arrived
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

    /// Whether THIS station is the one playing. The badge's one condition.
    private var isRunning: Bool {
        if case .running = RadioMyStations.cardLine(
            isRunning: coordinator.activeItem?.id == stationID,
            runningLine: coordinator.nowPlayingLine,
            seconds: listenedSeconds) { return true }
        return false
    }

    /// "3 Std.". The measured time, rounded down to full hours (the floor
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
        let ink: Color

        var body: some View {
            // ONE line, fixed height, whatever the state. The badge rides
            // INSIDE the line. A static LIVE outside it would be a false
            // statement while an audiobook plays.
            HStack(spacing: 6) {
                if isRunning { LiveBadge() }
                Text(verbatim: text)
                    .font(.caption)
                    .foregroundStyle(ink)
                    .lineLimit(1, reservesSpace: true)
            }
        }
    }
}

/// The card row for the Zuletzt class. RadioView and Home share it.
///
/// The same row now also carries "My Stations", with the star glyph
/// and the listening time. NOT a second card class: the form already carried
/// the pill and the line machinery this row needs, and the user's rule is that
/// the FORM carries the behaviour. A card is an offer to continue, a tile is
/// an entry in a choice.
struct RadioFeaturedCardRow: View {
    let title: String
    let stations: [RadioStation]
    let playerCoordinator: PlayerCoordinator
    /// Ids that carry the star. Empty for the plain Zuletzt row.
    var favoriteIDs: Set<String> = []
    /// Measured seconds per station id. The card line's second state.
    var seconds: [String: Int] = [:]
    /// The counted heading with its full page, when the row has one.
    var destination: RadioRoute? = nil
    /// The stock behind the preview, for the counting heading.
    var total: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let destination {
                // The chevron is ALWAYS on for this row. The
                // counted variant hides it when total == shown, and with two
                // cards that suppressed the whole full page on the user's device.
                // This page is not "see more": it is where the two sources
                // divide again and where an excluded favorite REAPPEARS. His
                // rule is hard now: every starred favorite is reachable in at
                // most two taps. Without the entry the excluded one is not
                // relocated, it is GONE. `.entry`: the chevron is earned by
                // the target's existence, not by a count.
                RowHeading<RadioRoute>.entry(verbatim: title, destination: destination)
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
/// rows. Tap opens the page, play stays the explicit control (the one
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

/// The region picker sheet. Curated state list with a
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
/// curation rules. No hardcoded lists), searchable; choosing persists the
/// explicit country and resets the old country's region choice.
///
/// The SAME list serves the genre pages' multi-select. One country
/// surface, one curation, one loading state. `selection` nil keeps the
/// single-choice behaviour (national/region rows, unchanged); a non-nil set
/// switches to toggling with a worldwide row on top.
struct RadioCountryPickerList: View {
    let onChoose: (_ code: String, _ name: String) -> Void
    /// Currently selected codes. Nil means single choice. An EMPTY set is a
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
                    // With an EMPTY LabeledContent value
                    // the button flattened to a bare StaticText in the a11y
                    // tree and lost its identifier. Combine keeps it a button.
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
