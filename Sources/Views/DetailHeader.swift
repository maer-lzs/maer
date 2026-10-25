// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// THE head of every detail page with a cover (book, album, playlist,
/// artist, show, episode, station, catalog series): the cover, under it the
/// title and its lines, the facts, then the page's controls. Cover, title,
/// lines and controls stand on one centre axis, the cover's, in every
/// posture and on every device; the facts (a table, a description) read
/// from the leading edge. A page hands in only its contents, in one and two
/// columns alike.
struct DetailHeader<Cover: View, Lines: View, Facts: View, Actions: View>: View {
    /// Absent where the page names itself elsewhere (the artist, by the
    /// navigation title).
    var title: String?
    var titleStyle: AnyShapeStyle = AnyShapeStyle(.primary)
    /// The side inset of title and lines, for a page whose cover runs to
    /// the edges.
    var textInset: CGFloat = 0
    @ViewBuilder var cover: () -> Cover
    @ViewBuilder var lines: () -> Lines
    @ViewBuilder var facts: () -> Facts
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 14) {
            if Cover.self != EmptyView.self {
                cover()
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
    }
}

extension DetailHeader where Facts == EmptyView {
    init(title: String?, titleStyle: AnyShapeStyle = AnyShapeStyle(.primary), textInset: CGFloat = 0,
         @ViewBuilder cover: @escaping () -> Cover, @ViewBuilder lines: @escaping () -> Lines,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.init(title: title, titleStyle: titleStyle, textInset: textInset,
                  cover: cover, lines: lines, facts: { EmptyView() }, actions: actions)
    }
}

extension DetailHeader where Actions == EmptyView {
    init(title: String?, titleStyle: AnyShapeStyle = AnyShapeStyle(.primary), textInset: CGFloat = 0,
         @ViewBuilder cover: @escaping () -> Cover, @ViewBuilder lines: @escaping () -> Lines,
         @ViewBuilder facts: @escaping () -> Facts) {
        self.init(title: title, titleStyle: titleStyle, textInset: textInset,
                  cover: cover, lines: lines, facts: facts, actions: { EmptyView() })
    }
}
