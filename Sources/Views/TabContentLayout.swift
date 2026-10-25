// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import Combine

/// Shared top inset and section spacing for the scrollable content of all three
/// media tabs (audiobooks / podcasts / music). One source of truth so the
/// pull-down and the gap above the first row sit identically everywhere.
/// Music was the reference.
enum TabContentLayout {
    static let topInset: CGFloat = 8
    static let sectionSpacing: CGFloat = 24
}

/// Device finding: the poster/tile card family is 10%
/// narrower so at least two cards fit side by side on the largest iPhone (17
/// Pro Max). ONE central home for the fixed card widths so they never drift per
/// surface. The Featured card and the Recommended tile were each used at two
/// sizes.
/// THE cap for horizontal preview rows. Until now caps were the
/// exception. `prefix(` appeared once in HomeView, three times in
/// LibraryView, once in PodcastsView and NOT AT ALL in Music and Radio, with
/// scattered numbers (5, 15) that shared no basis. That explains several
/// findings of this week at once: "Fortsetzen" grew without bound, the radio
/// cold start was sluggish, the audiobook page loaded endlessly.
///
/// A row is the PREVIEW of a page. The complete stock belongs
/// behind the chevron, not in the preview.
nonisolated enum RowPreview {
    /// 12 shows four screens' worth on a phone (3 columns) and two on a
    /// regular width (6). Enough to feel like a shelf, few enough to scroll
    /// past in a flick. Deliberately BELOW the 15 that "Recently added"
    /// happened to use, because that number was never chosen either.
    static let limit = 12

    /// The chevron appears ONLY when there is more than the row shows.
    /// A row of three radio recents out of three total stays plain. The
    /// same rule the empty sort menu just failed.
    static func showsChevron(total: Int, shown: Int = limit) -> Bool {
        total > shown
    }

    /// The preview cut of a collection.
    static func cut<T>(_ items: [T], to limit: Int = limit) -> [T] {
        Array(items.prefix(limit))
    }
}

/// THE row heading, shared by every tab. Plain text while the
/// row shows all there is; a tappable heading with a chevron as soon as
/// something is hidden behind it (no affordance without a target).
///
/// One component instead of a per-tab rebuild, so the rule cannot
/// drift apart between rows: whether a chevron appears is decided by
/// `RowPreview.showsChevron`, never by the call site.
struct RowHeading<Destination: Hashable>: View {
    /// Three real variants make the number-bending (total:1/shown:0)
    /// obsolete. The variant carries the decision.
    enum Variant {
        /// Chevron by pure COUNTING (DIE REGEL): visible iff total > shown.
        case counted(total: Int, shown: Int)
        /// Area entry: the chevron is earned by the target's existence.
        case entry
        /// No target. Plain heading, spelled out.
        case none
        /// Third variant (Up-Next): the heading performs an ACTION (opens the
        /// queue sheet) instead of pushing a route. Chevron always on.
        case action(@MainActor () -> Void)
    }

    let title: LocalizedStringKey
    /// Already-localized text (e.g. a sort option's label). Kept apart from
    /// `title` so a translated string is never looked up as a key again.
    var verbatimTitle: String?
    var font: Font = .title3
    var variant: Variant = .none
    var destination: Destination?
    /// Name the counted total in the chevron label (stock previews).
    var showsTotal: Bool = false
    /// A discreet SYMBOL action next to the chevron. The
    /// shuffle gesture of the music catalog rows. Deliberately the sort-symbol
    /// form, NOT a glass button: it belongs to the heading, not on
    /// top of the content. nil = no accessory, which is every other row.
    var accessorySymbol: String?
    var accessoryLabel: LocalizedStringKey = ""
    var accessoryAction: (@MainActor () -> Void)?

    var body: some View {
        if let accessorySymbol, let accessoryAction {
            HStack(spacing: 8) {
                headingBody
                Spacer(minLength: 4)
                Button(action: accessoryAction) {
                    Image(systemName: accessorySymbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(accessoryLabel))
            }
        } else {
            headingBody
        }
    }

    @ViewBuilder
    private var headingBody: some View {
        switch variant {
        case .counted(let total, let shown):
            if let destination, RowPreview.showsChevron(total: total, shown: shown) {
                link(destination)
            } else {
                plainLabel
            }
        case .entry:
            if let destination { link(destination) } else { plainLabel }
        case .none:
            plainLabel
        case .action(let perform):
            Button(action: perform) {
                chevronLabel
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Shows the full list"))
        }
    }

    private func link(_ destination: Destination) -> some View {
        NavigationLink(value: destination) {
            chevronLabel
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Shows the full list"))
    }

    private var chevronLabel: some View {
        HStack(spacing: 6) {
            label.font(font).bold()
            // The stock surfaces name their TOTAL in the chevron
            // ("Alle Bücher · 221 ›"). Opt-in via `showsTotal`, rendered
            // HERE so no call site invents its own number formatting.
            if showsTotal, case .counted(let total, _) = variant {
                Text(verbatim: "· \(total)")
                    .font(font).bold()
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .contentShape(.rect)
    }

    private var plainLabel: some View {
        label.font(font).bold().padding(.horizontal)
    }

    private var label: Text {
        if let verbatimTitle { Text(verbatimTitle) } else { Text(title) }
    }

    /// Counted heading. The standard form (kept as the memberwise-style
    /// entry point so existing call sites read unchanged).
    /// `showsTotal`: the two stock previews name their total in
    /// the chevron label; preview rows keep the plain chevron.
    init(title: LocalizedStringKey, verbatimTitle: String? = nil, font: Font = .title3,
         total: Int, shown: Int = RowPreview.limit, showsTotal: Bool = false,
         destination: Destination?) {
        self.title = title
        self.verbatimTitle = verbatimTitle
        self.font = font
        self.showsTotal = showsTotal
        self.variant = .counted(total: total, shown: shown)
        self.destination = destination
    }

    init(title: LocalizedStringKey, verbatimTitle: String?, font: Font,
         variant: Variant, destination: Destination?) {
        self.title = title
        self.verbatimTitle = verbatimTitle
        self.font = font
        self.variant = variant
        self.destination = destination
    }
}


extension RowHeading where Destination == LibraryListRoute {
    /// A row that already shows everything it has: heading only, no target.
    /// Spelled out at the call site so "no chevron" reads as a decision.
    static func plain(_ title: LocalizedStringKey, font: Font = .title3) -> Self {
        RowHeading(title: title, verbatimTitle: nil, font: font, variant: .none, destination: nil)
    }

    /// Same, for a heading whose text is already localized (a sort label).
    static func plain(verbatim title: String, font: Font = .title3) -> Self {
        RowHeading(title: "", verbatimTitle: title, font: font, variant: .none, destination: nil)
    }

    /// The ACTION heading (Up-Next → queue sheet): no route, always a
    /// chevron. The third variant the enum was rebuilt for.
    static func action(_ title: LocalizedStringKey, font: Font = .title3,
                       perform: @escaping @MainActor () -> Void) -> Self {
        RowHeading(title: title, verbatimTitle: nil, font: font,
                   variant: .action(perform), destination: nil)
    }
}

extension RowHeading {
    /// An AREA ENTRY: the chevron is always earned because a whole page lies
    /// behind it. Its own variant now, no number-bending.
    static func entry(_ title: LocalizedStringKey, font: Font = .title3,
                      destination: Destination) -> Self {
        RowHeading(title: title, verbatimTitle: nil, font: font,
                   variant: .entry, destination: destination)
    }

    /// Entry with an already-localized title (source proper names).
    static func entry(verbatim title: String, font: Font = .title3,
                      destination: Destination) -> Self {
        RowHeading(title: "", verbatimTitle: title, font: font,
                   variant: .entry, destination: destination)
    }
}

enum CardMetrics {
    /// Large "Featured" continue-cards. Books AND podcasts share this, so the
    /// two never drift apart (235 → 211, ×0.9).
    static let featuredCardWidth: CGFloat = 211

    // containerRelativeFrame column counts for the HORIZONTAL card rows. The
    // responsive replacement of fixed pt widths (screen-relative slots + a
    // natural peek of the next card). Design dial: the counts are tuned on
    // device; regular width (iPad/landscape) shows roughly double.
    //
    // Deliberately `fileprivate` and asked by the ONE modifier below.
    // As a public function taking a Bool it invited the wrong answer, and
    // fifteen of nineteen call sites took it up: they passed the literal
    // `false`, which on an iPad means full width ÷ 3. Record covers the size
    // of a palm. A caller cannot answer an environment question; the row can.
    // The three former dials (recommendation / playlist / rediscover) held the
    // same numbers and are one dial again.
    fileprivate static func columns(regularWidth: Bool) -> Int { regularWidth ? 6 : 3 }
}

/// THE slot of a horizontal card row. It reads the size class itself, so no
/// caller can misstate it. The difference between iPhone and iPad is not a
/// property of the row's content.
private struct CardRowSlot: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let spacing: CGFloat

    func body(content: Content) -> some View {
        content.containerRelativeFrame(
            .horizontal,
            count: CardMetrics.columns(regularWidth: horizontalSizeClass == .regular),
            span: 1, spacing: spacing)
    }
}

extension View {
    /// Card rows use 12 pt between tiles, the artwork-heavy music rows 14.
    func cardRowSlot(spacing: CGFloat = 12) -> some View {
        modifier(CardRowSlot(spacing: spacing))
    }
}

// MARK: - Shuffle gesture as a shared extension

extension RowHeading {
    /// Shuffle play on an archive.org music row, drawing from the WHOLE
    /// shelf rather than from the preview. The row is today's pick from the
    /// good part, this button reaches across everything: two gestures, two
    /// meanings.
    @MainActor
    func catalogShuffle(area: ArchiveMusicArea, coordinator: PlayerCoordinator) -> RowHeading {
        var copy = self
        copy.accessorySymbol = "shuffle"
        copy.accessoryLabel = "Play something at random"
        copy.accessoryAction = { Task { await CatalogShuffle.play(area: area, coordinator: coordinator) } }
        return copy
    }

    /// The same for Jamendo. Via a random offset, because that API has no
    /// random sort order (measured).
    @MainActor
    func jamendoShuffle(tags: [String] = [], coordinator: PlayerCoordinator) -> RowHeading {
        var copy = self
        copy.accessorySymbol = "shuffle"
        copy.accessoryLabel = "Play something at random"
        copy.accessoryAction = { Task { await CatalogShuffle.playJamendo(tags: tags, coordinator: coordinator) } }
        return copy
    }
}

/// "Play something at random" in a catalogue area page's menu
/// (`pageActions`): the one entry every area page carries, each with the
/// draw of its catalogue (`CatalogShuffle`), through `catalogShuffleActions`.
struct CatalogShuffleEntry: View {
    /// A draw is running; a second one waits for it.
    let busy: Bool
    let start: () -> Void

    var body: some View {
        Button(action: start) {
            Label("Play something at random", systemImage: "shuffle")
        }
        .disabled(busy)
        .accessibilityIdentifier("catalog-shuffle")
    }
}

extension View {
    /// A catalogue area page's one menu with its draw. The draw runs as the
    /// page's own task: leaving the page cancels it, and a cancelled draw
    /// starts nothing (`CatalogShuffle`). While it waits, the menu shows a
    /// spinner (`pageActions(busy:)`).
    func catalogShuffleActions(shown: Bool = true, draw: @escaping @MainActor () async -> Void) -> some View {
        modifier(CatalogShuffleActions(shown: shown, draw: draw))
    }
}

private struct CatalogShuffleActions: ViewModifier {
    let shown: Bool
    let draw: @MainActor () async -> Void
    /// The running draw; nil while none runs.
    @State private var request: UUID?

    func body(content: Content) -> some View {
        content
            .pageActions("catalog-actions", shown: shown, busy: request != nil) {
                CatalogShuffleEntry(busy: request != nil) { request = UUID() }
            }
            .task(id: request) {
                guard let running = request else { return }
                await draw()
                if request == running { request = nil }
            }
            // A page that comes back does not draw again on its own.
            .onDisappear { request = nil }
    }
}


/// "Play Next" / "Play Last" for catalogue titles.
/// `PlayQueue` already stores arbitrary ids across sources. Only the entry
/// points were missing. ONE building block for every catalogue
/// tile (music AND books), so the next surface does not reinvent it.
struct CatalogQueueButtons: View {
    let itemId: String
    /// Several ids (album, queue). The same action with a set instead of one.
    var itemIds: [String]?
    /// Titles the surface has at hand, passed straight through.
    var knownTitles: [String: String] = [:]

    private var ids: [String] { itemIds ?? [itemId] }

    var body: some View {
        if PlayQueue.canEnqueue(itemId) {
            Button {
                for id in ids.reversed() { PlayQueue.shared.playNext(id) }
            } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
            Button {
                for id in ids { PlayQueue.shared.playLast(id) }
            } label: { Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") }
            // The playlist action exists EXACTLY ONCE. A second
            // copy here carried the same defect twice.
            AddToPlaylistButton(itemId: itemId, itemIds: itemIds, knownTitles: knownTitles)
        }
    }
}

/// A preview row whose content is SWITCHED by a selector strip above it.
/// Heading, optional sender line, the strip, and the row itself with its
/// loading, empty and failure states.
///
/// One component for both places that need this shape: the radio-play charts
/// (chips select a genre) and the 78rpm shelves (tiles select a shelf). The
/// second one used the same layout, so it is a parameter, not a copy.
struct SwitchableTileRow<Heading: View, Selector: View, Content: View>: View {
    enum LoadState { case loading, failed, empty, ready }

    let state: LoadState
    /// Shown under the heading when the content comes from a named source.
    var senderLine: String?
    var emptyText: LocalizedStringKey = "Nothing here right now."
    var failedText: LocalizedStringKey = "This could not be loaded. Check your connection."
    @ViewBuilder var heading: () -> Heading
    @ViewBuilder var selector: () -> Selector
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading()
            if let senderLine {
                Text(verbatim: senderLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            selector()
            switch state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            case .failed:
                message(failedText)
            case .empty:
                message(emptyText)
            case .ready:
                content()
            }
        }
    }

    private func message(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
    }
}

/// A row that already takes its space during a cold pass: the same heading
/// as the real one, tile skeletons of the same size below it. It replaces
/// itself as soon as the content arrives, so nothing jumps.
///
/// ONE component for every surface that waits for shelves: the book sources
/// and the two music surfaces. A second copy would drift, and the question
/// it answers ("does this wait deserve to be said?") is the same one
/// everywhere.
struct ShelfPlaceholderRow: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RowHeading.plain(verbatim: title)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(0..<RowPreview.limit, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                            .aspectRatio(1, contentMode: .fit)
                            .cardRowSlot(spacing: 14)
                    }
                }
                .padding(.horizontal)
            }
            .rowReachesUnderSideColumn()
            .allowsHitTesting(false)
        }
        .accessibilityHidden(true)
    }
}

extension SwitchableTileRow where Selector == EmptyView {
    /// A row WITHOUT a selector: heading, then tiles. An ordinary catalogue
    /// row keeps the loading and the failure state this way, instead of
    /// building its own stack that would show neither.
    init(state: LoadState, senderLine: String? = nil,
         emptyText: LocalizedStringKey = "Nothing here right now.",
         failedText: LocalizedStringKey = "This could not be loaded. Check your connection.",
         @ViewBuilder heading: @escaping () -> Heading,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(state: state, senderLine: senderLine, emptyText: emptyText,
                  failedText: failedText, heading: heading,
                  selector: { EmptyView() }, content: content)
    }
}

/// The rights notice stands on EVERY surface whose content comes from
/// archive.org: Old Time Radio, netlabels, the shellac shelves and the
/// archive audiobooks.
///
/// ONE wording, ONE component, not four text variants that drift apart. It
/// stands at the START of the surface rather than in a footnote nobody reads.
/// No legal advice, no paragraph, one sentence.
struct ArchiveRightsNote: View {
    var body: some View {
        Label {
            Text(verbatim: FreeCatalog.archiveRightsNotice)
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
        .foldLeadingHalf()
    }
}
