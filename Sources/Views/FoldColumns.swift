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

    var body: some View {
        GeometryReader { geo in
            let columns = FoldSplit.columns(contentMinX: geo.frame(in: .global).minX,
                                            contentWidth: geo.size.width,
                                            fold: foldLine.fold, windowWidth: foldLine.windowWidth)
            HStack(spacing: 0) {
                leading(CGSize(width: columns.leading, height: geo.size.height))
                    .frame(width: columns.leading)
                Color.clear.frame(width: columns.gap)
                trailing(CGSize(width: columns.trailing, height: geo.size.height))
                    .frame(width: columns.trailing)
            }
        }
    }
}

/// A scrolling page (the artist) in its two forms: narrow, the header above
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
                            .padding(.vertical)
                            .bottomBarClearance()
                    }
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
            if BookDetailLayout.of(width: geo.size.width, height: geo.size.height,
                                   compactHeight: verticalSizeClass == .compact) == .twoColumns {
                FoldColumns { _ in
                    ScrollView {
                        header()
                            .padding(.top, 8)
                            .bottomBarClearance()
                    }
                    .scrollContentBackground(.hidden)
                    .reportsBottomBarScroll()
                } trailing: { _ in
                    List { rows() }
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
}
