// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import Combine

/// Shared top inset and section spacing for the scrollable content of all three
/// media tabs (audiobooks / podcasts / music). One source of truth so the
/// pull-down and the gap above the first row sit identically everywhere —
/// Music was the reference.
enum TabContentLayout {
    static let topInset: CGFloat = 8
    static let sectionSpacing: CGFloat = 24
}

/// Device finding: the poster/tile card family is 10%
/// narrower so at least two cards fit side by side on the largest iPhone (17
/// Pro Max). ONE central home for the fixed card widths so they never drift per
/// surface (Regel 2 — the Featured card and the Recommended tile were each used
/// at two sizes). First step only — a device-loop CANDIDATE; the
/// exact factor on the device.
/// 6fcb301: THE cap for horizontal preview rows. Until now caps were the
/// exception — `prefix(` appeared once in HomeView, three times in
/// LibraryView, once in PodcastsView and NOT AT ALL in Music and Radio, with
/// scattered numbers (5, 15) that shared no basis. That explains several
/// findings of this week at once: "Fortsetzen" grew without bound, the radio
/// cold start was sluggish, the audiobook page loaded endlessly.
///
/// A row is the PREVIEW of a page (3a3b1aa) — the complete stock belongs
/// behind the chevron, not in the preview.
nonisolated enum RowPreview {
    /// 12 shows four screens' worth on a phone (3 columns) and two on a
    /// regular width (6) — enough to feel like a shelf, few enough to scroll
    /// past in a flick. Deliberately BELOW the 15 that "Recently added"
    /// happened to use, because that number was never chosen either.
    static let limit = 12

    /// G8: the chevron appears ONLY when there is more than the row shows.
    /// A row of three radio recents out of three total stays plain — the
    /// same rule the empty sort menu just failed.
    static func showsChevron(total: Int, shown: Int = limit) -> Bool {
        total > shown
    }

    /// The preview cut of a collection.
    static func cut<T>(_ items: [T], to limit: Int = limit) -> [T] {
        Array(items.prefix(limit))
    }
}

/// 3a3b1aa/6fcb301: THE row heading, shared by every tab. Plain text while the
/// row shows all there is; a tappable heading with a chevron as soon as
/// something is hidden behind it (G8 — no affordance without a target).
///
/// One component instead of a per-tab rebuild (Regel 2), so the rule cannot
/// drift apart between rows: whether a chevron appears is decided by
/// `RowPreview.showsChevron`, never by the call site.
struct RowHeading<Destination: Hashable>: View {
    /// e268c70/13c5094 GO: three real variants made the number-bending
    /// (total:1/shown:0) obsolete — the variant IS the decision now.
    enum Variant {
        /// Chevron by pure COUNTING (DIE REGEL): visible iff total > shown.
        case counted(total: Int, shown: Int)
        /// Area entry: the chevron is earned by the target's existence.
        case entry
        /// No target — plain heading, spelled out.
        case none
        /// Third variant (Up-Next): the heading performs an ACTION (opens the
        /// queue sheet) instead of pushing a route — chevron always on.
        case action(@MainActor () -> Void)
    }

    let title: LocalizedStringKey
    /// Already-localized text (e.g. a sort option's label). Kept apart from
    /// `title` so a translated string is never looked up as a key again.
    var verbatimTitle: String?
    var font: Font = .title3
    var variant: Variant = .none
    var destination: Destination?
    /// Auftrag J: name the counted total in the chevron label (stock previews).
    var showsTotal: Bool = false
    /// M2 (09.08.): a discreet SYMBOL action next to the chevron — the
    /// shuffle gesture of the music catalog rows. Deliberately the sort-symbol
    /// form (fb21fbd), NOT a glass button: it belongs to the heading, not on
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
            if let destination, total > shown {
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
            // Auftrag J: the stock surfaces name their TOTAL in the chevron
            // ("Alle Bücher · 221 ›") — opt-in via `showsTotal`, rendered
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

    /// Counted heading — the standard form (kept as the memberwise-style
    /// entry point so existing call sites read unchanged).
    /// `showsTotal` (Auftrag J): the two stock previews name their total in
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
    /// chevron — the third variant the enum was rebuilt for (e268c70 GO).
    static func action(_ title: LocalizedStringKey, font: Font = .title3,
                       perform: @escaping @MainActor () -> Void) -> Self {
        RowHeading(title: title, verbatimTitle: nil, font: font,
                   variant: .action(perform), destination: nil)
    }
}

extension RowHeading {
    /// An AREA ENTRY: the chevron is always earned because a whole page lies
    /// behind it — its own variant now, no number-bending (e268c70).
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
    /// Large "Featured" continue-cards — books AND podcasts share this, so the
    /// two never drift apart (235 → 211, ×0.9).
    static let featuredCardWidth: CGFloat = 211
    /// Discover / Recommended catalog tiles — Home AND the podcast tab, one size
    /// (was 140 / 132; now 126, ×0.9 of the larger).
    static let recommendationTileWidth: CGFloat = 126

    // containerRelativeFrame column counts for the HORIZONTAL card rows — the
    // responsive replacement of fixed pt widths (screen-relative slots + a
    // natural peek of the next card). Design dial: the counts are tuned on
    // device; regular width (iPad/landscape) shows roughly double.
    static func recommendationColumns(regularWidth: Bool) -> Int { regularWidth ? 6 : 3 }
    static func playlistColumns(regularWidth: Bool) -> Int { regularWidth ? 6 : 3 }
    static func rediscoverColumns(regularWidth: Bool) -> Int { regularWidth ? 6 : 3 }
}

// MARK: - Shuffle gesture as a shared extension

extension RowHeading {
    /// „Zufällig abspielen" an einer archive.org-Musikreihe — aus dem GANZEN
    /// shelf, not from the preview. The row is today's pick from the good
    /// stuff, this button reaches across everything: two gestures, two
    /// meanings.
    @MainActor
    func catalogShuffle(area: ArchiveMusicArea, coordinator: PlayerCoordinator) -> RowHeading {
        var copy = self
        copy.accessorySymbol = "shuffle"
        copy.accessoryLabel = "Play something at random"
        copy.accessoryAction = { Task { await CatalogShuffle.play(area: area, coordinator: coordinator) } }
        return copy
    }

    /// The same for Jamendo — via a random offset, because that API has no
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


/// The state behind the playlist dialogs.
///
/// A button inside a `contextMenu` can only flip a state — the presentation
/// must hang OUTSIDE the menu, because the menu's hierarchy is torn down when
/// it closes and an alert attached there is never presented. So the menu only
/// triggers, this type holds the state, and `RootView` presents. That also
/// spares every call site from threading a binding through.
@MainActor
final class MaerPlaylistPresenter: ObservableObject {
    static let shared = MaerPlaylistPresenter()
    private init() {}

    /// What to add once the name is entered.
    @Published var pendingIds: [String] = []
    @Published var askingForName = false
    @Published var message: String?

    func addToNewList(_ ids: [String]) {
        pendingIds = ids
        askingForName = true
    }

    func add(_ ids: [String], to list: MaerPlaylists.Playlist) {
        message = Self.text(for: MaerPlaylists.shared.add(itemIds: ids, to: list.id),
                            listName: list.name)
    }

    func createAndAdd(name rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = name.isEmpty ? String(localized: "Playlist") : name
        let list = MaerPlaylists.shared.create(name: finalName)
        message = Self.text(for: MaerPlaylists.shared.add(itemIds: pendingIds, to: list.id),
                            listName: finalName)
        pendingIds = []
    }

    /// Regel 3: every outcome gets a sentence — including "was already in
    /// there" and above all the limit, which is reported instead of truncating
    /// silently.
    static func text(for outcome: MaerPlaylists.AddOutcome, listName: String) -> String? {
        switch outcome {
        case .added:         return nil
        case .alreadyThere:  return String(localized: "Already in “\(listName)”.")
        case .limitReached(let limit):
            // The limit is not a private quota: playlists and podcast progress
            // share ONE iCloud budget, so the message must not suggest the
            // playlists had a compartment of their own (Entscheid f35db87).
            return String(localized: "Your playlists are full (\(limit) entries) — they share the iCloud space with your podcast progress. Remove something first.")
        case .notQueueable:  return String(localized: "This cannot be added to a playlist.")
        }
    }
}

extension View {
    /// Belongs at the root ONCE: the playlist dialogs are presented here
    /// because they must not hang off a menu hierarchy.
    func maerPlaylistDialogs() -> some View { modifier(MaerPlaylistDialogs()) }
}

private struct MaerPlaylistDialogs: ViewModifier {
    @ObservedObject private var presenter = MaerPlaylistPresenter.shared
    @State private var newListName = ""

    func body(content: Content) -> some View {
        content
            .alert("New Playlist", isPresented: $presenter.askingForName) {
                TextField("Name", text: $newListName)
                    .accessibilityIdentifier("new-playlist-name")
                Button("Create") {
                    presenter.createAndAdd(name: newListName)
                    newListName = ""
                }
                Button("Cancel", role: .cancel) {
                    presenter.pendingIds = []
                    newListName = ""
                }
            }
            .alert("Playlist", isPresented: Binding(get: { presenter.message != nil },
                                                    set: { if !$0 { presenter.message = nil } })) {
                Button("OK", role: .cancel) { presenter.message = nil }
            } message: {
                if let message = presenter.message { Text(verbatim: message) }
            }
    }
}

/// M3 (Auftrag 09.08.): „Als Nächstes" / „Zuletzt einreihen" für Katalog-Titel.
/// `PlayQueue` speichert schon heute beliebige Kennungen quellenübergreifend —
/// only the entry points were missing. ONE building block for every catalogue
/// tile (music AND books), so the next surface does not reinvent it.
struct CatalogQueueButtons: View {
    let itemId: String
    /// Several ids (album, queue) — the same action with a set instead of one.
    var itemIds: [String]?

    private var ids: [String] { itemIds ?? [itemId] }

    var body: some View {
        if PlayQueue.canEnqueue(itemId) {
            Button {
                for id in ids.reversed() { PlayQueue.shared.playNext(id) }
            } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
            Button {
                for id in ids { PlayQueue.shared.playLast(id) }
            } label: { Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") }
            // The playlist action exists EXACTLY ONCE (Regel 2). A second
            // copy here carried the same defect twice.
            MaerPlaylistMenu(itemId: itemId, itemIds: itemIds)
        }
    }
}

/// THE playlist action — menu content, nothing else. Presentation happens at
/// the root (`maerPlaylistDialogs`), because a context menu takes its dialogs
/// with it when it closes.
struct MaerPlaylistMenu: View {
    let itemId: String
    var itemIds: [String]?
    @ObservedObject private var playlists = MaerPlaylists.shared

    private var ids: [String] { itemIds ?? [itemId] }

    var body: some View {
        if PlayQueue.canEnqueue(itemId) {
            Menu {
                ForEach(playlists.playlists) { list in
                    Button(list.name) { MaerPlaylistPresenter.shared.add(ids, to: list) }
                }
                if !playlists.playlists.isEmpty { Divider() }
                Button {
                    MaerPlaylistPresenter.shared.addToNewList(ids)
                } label: { Label("New Playlist", systemImage: "plus") }
            } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
        }
    }
}

/// A preview row whose content is SWITCHED by a selector strip above it —
/// heading, optional sender line, the strip, and the row itself with its
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
