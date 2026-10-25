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

extension View {
    /// The page's view as the room of its head's cover (`DetailHeaderRoom`).
    func givesDetailHeaderRoom(top: CGFloat) -> some View {
        GeometryReader { geo in
            environment(\.detailHeaderRoom, DetailHeaderRoom(height: geo.size.height, top: top))
        }
    }
}

/// THE head of every detail page with a cover (book, album, playlist,
/// artist, show, episode, station, catalog series): the cover, under it the
/// title and its lines, the facts, then the page's controls. Cover, title,
/// lines and controls stand on one centre axis, the cover's, in every
/// posture and on every device; the facts (a table, a description) read
/// from the leading edge. A page hands in only its contents, in one and two
/// columns alike.
///
/// Where the page gives the room (`DetailHeaderRoom`), the cover is as wide
/// as the head while everything below it down to the controls stays above
/// the playback bar, else as large as the height leaves (`DetailCoverSide`);
/// the cover closure receives that side. Without the room it receives nil
/// and the page sizes the cover itself (the book page, which sizes its own).
struct DetailHeader<Cover: View, Lines: View, Facts: View, Actions: View>: View {
    /// Absent where the page names itself elsewhere (the artist, by the
    /// navigation title).
    var title: String?
    var titleStyle: AnyShapeStyle = AnyShapeStyle(.primary)
    /// The side inset of title and lines, for a page whose cover runs to
    /// the edges.
    var textInset: CGFloat = 0
    @ViewBuilder var cover: (CGFloat?) -> Cover
    @ViewBuilder var lines: () -> Lines
    @ViewBuilder var facts: () -> Facts
    @ViewBuilder var actions: () -> Actions

    @Environment(\.detailHeaderRoom) private var room
    @Environment(\.bottomBarInset) private var bottomBarInset
    @State private var width: CGFloat = 0
    /// The head's height without the cover, kept through
    /// `DetailCoverSide.settled` so the page comes to rest.
    @State private var below: CGFloat = 0
    @State private var coverHeight: CGFloat = 0
    @State private var headHeight: CGFloat = 0

    private var coverSide: CGFloat? {
        guard let room, width > 0 else { return nil }
        return DetailCoverSide.side(columnWidth: width, height: room.height, top: room.top,
                                    below: below, bottomReserve: bottomBarInset)
    }

    private func noteBelow() {
        below = DetailCoverSide.settled(below, measured: max(0, headHeight - coverHeight))
    }

    var body: some View {
        VStack(spacing: 14) {
            if Cover.self != EmptyView.self {
                cover(coverSide)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        coverHeight = $0
                        noteBelow()
                    }
                    .frame(maxWidth: .infinity)
            }
            if title != nil || Lines.self != EmptyView.self {
                VStack(spacing: 4) {
                    if let title {
                        Text(verbatim: title)
                            .font(.title2.bold())
                            .foregroundStyle(titleStyle)
                    }
                    lines()
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, textInset)
            }
            if Facts.self != EmptyView.self {
                facts()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if Actions.self != EmptyView.self {
                actions()
                    .frame(maxWidth: .infinity)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: {
            width = $0.width
            headHeight = $0.height
            noteBelow()
        }
        // A new window starts the kept height again.
        .onChange(of: room) { _, _ in below = 0 }
    }
}

extension DetailHeader where Facts == EmptyView {
    init(title: String?, titleStyle: AnyShapeStyle = AnyShapeStyle(.primary), textInset: CGFloat = 0,
         @ViewBuilder cover: @escaping (CGFloat?) -> Cover, @ViewBuilder lines: @escaping () -> Lines,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.init(title: title, titleStyle: titleStyle, textInset: textInset,
                  cover: cover, lines: lines, facts: { EmptyView() }, actions: actions)
    }
}

extension DetailHeader where Actions == EmptyView {
    init(title: String?, titleStyle: AnyShapeStyle = AnyShapeStyle(.primary), textInset: CGFloat = 0,
         @ViewBuilder cover: @escaping (CGFloat?) -> Cover, @ViewBuilder lines: @escaping () -> Lines,
         @ViewBuilder facts: @escaping () -> Facts) {
        self.init(title: title, titleStyle: titleStyle, textInset: textInset,
                  cover: cover, lines: lines, facts: facts, actions: { EmptyView() })
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
