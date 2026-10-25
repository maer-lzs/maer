// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The room a page gives its head's cover: the height of the page's view
/// and the distance from its top to the cover at rest.
struct DetailHeaderRoom: Equatable {
    var height: CGFloat
    var top: CGFloat
}

extension EnvironmentValues {
    @Entry var detailHeaderRoom: DetailHeaderRoom? = nil
}

/// THE head of every detail page with a cover (book, album, playlist,
/// artist, show, episode, station, catalog series): the cover, under it the
/// title and its lines, the facts, then the page's controls. Cover, title,
/// lines and controls stand on one centre axis, the cover's, in every
/// posture and on every device; the facts (a table, a description) read
/// from the leading edge. A page hands in only its contents, in one and two
/// columns alike. The title stands only here, never in the top bar
/// (`untitledDetailPage`).
///
/// Where the page gives the room (`DetailHeaderRoom`), the cover is sized
/// once from the head's width and the room's height (`DetailCoverSide`);
/// what does not fit lies under the playback bar. The cover closure
/// receives that side. Only the leading column of a
/// two-column page gives the room; without it the closure receives nil and
/// the page sizes the cover itself (one column, and the book page, which
/// sizes its own).
struct DetailHeader<Cover: View, Lines: View, Facts: View, Actions: View>: View {
    var title: String
    var titleStyle: AnyShapeStyle = AnyShapeStyle(.primary)
    /// The side inset of title and lines, for a page whose head keeps no
    /// side margin of its own.
    var textInset: CGFloat = 0
    @ViewBuilder var cover: (CGFloat?) -> Cover
    @ViewBuilder var lines: () -> Lines
    @ViewBuilder var facts: () -> Facts
    @ViewBuilder var actions: () -> Actions

    @Environment(\.detailHeaderRoom) private var room
    @State private var width: CGFloat = 0

    private var coverSide: CGFloat? {
        guard let room, width > 0 else { return nil }
        return DetailCoverSide.side(columnWidth: width, height: room.height, top: room.top)
    }

    var body: some View {
        VStack(spacing: 14) {
            if Cover.self != EmptyView.self {
                cover(coverSide)
                    .frame(maxWidth: .infinity)
            }
            VStack(spacing: 4) {
                Text(verbatim: title)
                    .font(.title2.bold())
                    .foregroundStyle(titleStyle)
                lines()
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, textInset)
            if Facts.self != EmptyView.self {
                facts()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if Actions.self != EmptyView.self {
                actions()
                    .frame(maxWidth: .infinity)
            }
        }
        // The head's width is the column's room; nothing under the cover
        // is measured.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

extension View {
    /// A page with a `DetailHeader` names itself under its cover: its top
    /// bar carries no title, at rest and scrolled.
    func untitledDetailPage() -> some View {
        navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
    }

    /// THE one place of a page's actions: a ⋯ menu at the trailing end of
    /// its top bar, where the system puts it with the tabs at the bottom and
    /// beside the side column alike. No other control of the page stands in
    /// its top bar. `shown` false leaves the bar empty on a page that has no
    /// action at the moment. `busy`: an action of the menu is still waiting;
    /// the menu shows a spinner in place of its mark, where the tap was.
    func pageActions<Entries: View>(_ id: String, shown: Bool = true, busy: Bool = false,
                                    @ViewBuilder entries: @escaping () -> Entries) -> some View {
        toolbar {
            if shown {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu { entries() } label: {
                        if busy {
                            ProgressView()
                        } else {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                    .accessibilityLabel(Text("Actions"))
                    .accessibilityValue(busy ? Text("Loading…") : Text(verbatim: ""))
                    .accessibilityIdentifier(id)
                }
            }
        }
    }
}

extension DetailHeader where Facts == EmptyView {
    init(title: String, titleStyle: AnyShapeStyle = AnyShapeStyle(.primary), textInset: CGFloat = 0,
         @ViewBuilder cover: @escaping (CGFloat?) -> Cover, @ViewBuilder lines: @escaping () -> Lines,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.init(title: title, titleStyle: titleStyle, textInset: textInset,
                  cover: cover, lines: lines, facts: { EmptyView() }, actions: actions)
    }
}

extension DetailHeader where Actions == EmptyView {
    init(title: String, titleStyle: AnyShapeStyle = AnyShapeStyle(.primary), textInset: CGFloat = 0,
         @ViewBuilder cover: @escaping (CGFloat?) -> Cover, @ViewBuilder lines: @escaping () -> Lines,
         @ViewBuilder facts: @escaping () -> Facts) {
        self.init(title: title, titleStyle: titleStyle, textInset: textInset,
                  cover: cover, lines: lines, facts: facts, actions: { EmptyView() })
    }
}

/// THE row of a detail head's links (website, transcript, support): among
/// the head's controls, on its centre axis, in one size.
struct DetailLinkRow<Links: View>: View {
    @ViewBuilder var links: () -> Links

    var body: some View {
        HStack(spacing: 18) { links() }
            .font(.subheadline)
            .frame(maxWidth: .infinity)
    }
}

/// THE main button of a detail head: glyph and word on light glass in a
/// rounded rectangle, the head's full width. Every head that starts and
/// pauses playback takes this one form; a disabled button keeps it.
struct DetailMainButton: View {
    var title: String
    var systemImage: String
    /// Starting: a spinner in place of the glyph.
    var isBusy = false
    var action: () -> Void

    static let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        Button(action: action) {
            HStack {
                if isBusy {
                    ProgressView()
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(.primary)
        }
        .modifier(AdaptiveGlassBackground(shape: Self.shape))
    }
}

/// Where a page's download stands, as its head shows it.
nonisolated enum DetailDownloadState: Equatable, Sendable {
    case none
    /// Running; the fraction, or below 0 when the size is unknown.
    case loading(Double)
    case stored
}

/// THE one place of a page's states in its head: what the page's menu
/// changes, seen without opening it, with no action of its own (the actions
/// stay in the ⋯ menu, `pageActions`). A filled heart while a favorite, the
/// grey arrow while stored, the progress while it loads (`DownloadingRing`).
/// Nothing when no
/// state holds. It stands as the last of the head's lines, under the title.
struct DetailStates: View {
    var favorite = false
    var download: DetailDownloadState = .none

    var body: some View {
        if favorite || download != .none {
            HStack(spacing: 12) {
                if favorite {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel(Text("Favorite"))
                }
                switch download {
                case .none:
                    EmptyView()
                case .loading(let fraction):
                    DownloadingRing(fraction: fraction)
                case .stored:
                    Image(systemName: DownloadedMark.symbol)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("Downloaded"))
                }
            }
            .font(.body)
            .padding(.top, 4)
            .accessibilityIdentifier("detail-states")
        }
    }
}
