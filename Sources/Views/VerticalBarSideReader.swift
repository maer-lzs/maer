// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import UIKit

extension View {
    /// Reports the edge at which the system stands its bars upright, nil
    /// where it keeps them at the bottom and on every system before 27.1.
    func readsVerticalBarSide(_ side: Binding<VerticalBarSide?>) -> some View {
        background { VerticalBarSideReader(side: side) }
    }

    /// Reports how far down the system reserves the strip at the window's
    /// right edge (status bar, camera), in window points: a bar of our own in
    /// that strip starts below it. 0 where nothing is reserved there.
    func readsReservedTop(ofStripWidth width: CGFloat, _ top: Binding<CGFloat>) -> some View {
        background { ReservedTopReader(stripWidth: width, top: top).accessibilityHidden(true) }
    }
}

/// Apple's way for a bar of our own: the window's occlusion regions
/// (`UIView.reservedRegions`, iOS 27.1), read whenever the window lays out.
private struct ReservedTopReader: UIViewRepresentable {
    let stripWidth: CGFloat
    @Binding var top: CGFloat

    func makeUIView(context: Context) -> ReaderView { ReaderView() }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.stripWidth = stripWidth
        view.report = { value in if top != value { top = value } }
        view.setNeedsLayout()
    }

    final class ReaderView: UIView {
        var stripWidth: CGFloat = 0
        var report: ((CGFloat) -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let window, stripWidth > 0 else { return }
            var bottom: CGFloat = 0
            if #available(iOS 27.1, *) {
                let strip = CGRect(x: window.bounds.maxX - stripWidth, y: 0,
                                   width: stripWidth, height: window.bounds.height)
                for region in window.reservedRegions(kind: .occlusion) where region.isActive
                    && region.frame.intersects(strip) {
                    bottom = max(bottom, region.frame.maxY)
                }
            }
            let value = bottom
            DispatchQueue.main.async { [report] in report?(value) }
        }
    }
}

private struct VerticalBarSideReader: View {
    @Binding var side: VerticalBarSide?

    var body: some View {
        if #available(iOS 27.1, *) {
            SystemEdge(side: $side)
        }
    }

    @available(iOS 27.1, *)
    private struct SystemEdge: View {
        @Binding var side: VerticalBarSide?
        @Environment(\.toolbarVerticalEdge) private var edge

        var body: some View {
            Color.clear
                .accessibilityHidden(true)
                .onChange(of: edge, initial: true) { _, edge in
                    switch edge {
                    case .leading: side = .leading
                    case .trailing: side = .trailing
                    case nil: side = nil
                    }
                }
        }
    }
}
