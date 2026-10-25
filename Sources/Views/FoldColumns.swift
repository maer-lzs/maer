// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// THE two columns of a detail page in a wide window (`FoldSplit`): the
/// leading column ends before the fold, the trailing one begins after it,
/// nothing lies over the fold. Each column learns its size. The book page
/// takes it directly, the show page, album and playlist through
/// `DetailListColumns`, the artist page through `DetailScrollColumns`.
struct FoldColumns<Leading: View, Trailing: View>: View {
    @Environment(\.foldLine) private var foldLine
    @ViewBuilder var leading: (CGSize) -> Leading
    @ViewBuilder var trailing: (CGSize) -> Trailing

    /// THE distance of both columns' content from the fold (`FoldSplit.foldDistance`).
    /// The frame gives all of it but the page's own gutter, which a page
    /// in it keeps on its fold edge at `FoldSplit.pageGutter`, the standard
    /// padding.
    static var foldMargin: CGFloat { FoldSplit.foldDistance - FoldSplit.pageGutter }

    var body: some View {
        GeometryReader { geo in
            let columns = FoldSplit.columns(contentMinX: geo.frame(in: .global).minX,
                                            contentWidth: geo.size.width,
                                            fold: foldLine.fold, windowWidth: foldLine.windowWidth)
            let margin = Self.foldMargin
            HStack(spacing: 0) {
                leading(CGSize(width: max(0, columns.leading - margin), height: geo.size.height))
                    .frame(width: max(0, columns.leading - margin))
                    .padding(.trailing, margin)
                Color.clear.frame(width: columns.gap)
                trailing(CGSize(width: max(0, columns.trailing - margin), height: geo.size.height))
                    .frame(width: max(0, columns.trailing - margin))
                    .padding(.leading, margin)
            }
        }
    }
}

extension View {
    /// THE look of a detail page's cover as a card (`DetailCoverCard`):
    /// round corners and a shadow. Every head's cover and the full player
    /// take it.
    func coverCard() -> some View {
        clipShape(RoundedRectangle(cornerRadius: DetailCoverCard.cornerRadius))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
    }
}

private extension View {
    /// Rows at the fold that keep the List's own inset (which differs from
    /// device to device) take the page gutter there instead; a row that sets
    /// its insets itself keeps them.
    @ViewBuilder func rowsTakeTheFoldGutter() -> some View {
        if #available(iOS 26, *) {
            listRowInsets(.leading, FoldSplit.pageGutter)
        } else {
            self
        }
    }
}

/// A scrolling page (the artist, the station) in its two forms: narrow, the header above
/// the content in one scroll, as before; wide, the header in the leading
/// column and the content in the trailing one, divided at the fold.
struct DetailScrollColumns<Header: View, Content: View>: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    var spacing: CGFloat
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geo in
            if BookDetailLayout.of(width: geo.size.width, height: geo.size.height,
                                   compactHeight: verticalSizeClass == .compact) == .twoColumns {
                FoldColumns { _ in
                    ScrollView {
                        header()
                            .padding(.vertical, Self.headTop)
                            .bottomBarClearance()
                    }
                    .leadingColumnRoom(height: geo.size.height, top: Self.headTop)
                } trailing: { _ in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: spacing) { content() }
                            .padding(.vertical)
                            .bottomBarClearance()
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: spacing) {
                        header()
                        content()
                    }
                    .padding(.vertical)
                    .bottomBarClearance()
                }
            }
        }
    }
}

/// A list page (show, album, playlist) in its two forms: narrow, the
/// header is the first row of the one list, as before; wide
/// (`BookDetailLayout.twoColumns`), the header stands in the leading column
/// and the rows in the trailing one, divided at the fold.
struct DetailListColumns<Header: View, Rows: View>: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ViewBuilder var header: () -> Header
    @ViewBuilder var rows: () -> Rows

    var body: some View {
        GeometryReader { geo in
            columns(geo)
        }
    }

    @ViewBuilder
    private func columns(_ geo: GeometryProxy) -> some View {
        if BookDetailLayout.of(width: geo.size.width, height: geo.size.height,
                               compactHeight: verticalSizeClass == .compact) == .twoColumns {
            FoldColumns { _ in
                ScrollView {
                    header()
                        .padding(.top, Self.headTop)
                        .bottomBarClearance()
                }
                .scrollContentBackground(.hidden)
                .reportsBottomBarScroll()
                .leadingColumnRoom(height: geo.size.height, top: Self.headTop)
            } trailing: { _ in
                List { rows().rowsTakeTheFoldGutter() }
                    .listStyle(.plain)
                    .barAwareList()
                    .reportsBottomBarScroll()
            }
        } else {
            List {
                header()
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                rows()
            }
            .listStyle(.plain)
            .barAwareList()
            .reportsBottomBarScroll()
        }
    }
}

private extension DetailListColumns {
    /// Where the head's cover begins in the leading column at rest: the
    /// head is the first thing in it, a little below the top.
    static var headTop: CGFloat { 8 }
}

private extension DetailScrollColumns {
    /// Where the head's cover begins in the leading column at rest.
    static var headTop: CGFloat { 16 }
}

private extension View {
    /// The leading column of a two-column page as the room of its head's
    /// cover; in one column the head keeps the cover its page sizes.
    func leadingColumnRoom(height: CGFloat, top: CGFloat) -> some View {
        environment(\.detailHeaderRoom, DetailHeaderRoom(height: height, top: top))
    }
}
