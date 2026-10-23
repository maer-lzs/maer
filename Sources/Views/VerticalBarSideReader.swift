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

    /// Reports what the system reserves in the strip at the window's right
    /// edge (status bar, camera): a bar of our own in that strip starts below
    /// it and stands on the axis of the system's own column.
    func readsReservedStrip(ofWidth width: CGFloat, _ reading: Binding<ReservedStrip>) -> some View {
        background { ReservedStripReader(stripWidth: width, reading: reading).accessibilityHidden(true) }
    }
}

/// What the system reserves in the side strip, in window points.
struct ReservedStrip: Equatable {
    /// How far down the reserved regions reach; 0 where nothing is there.
    var top: CGFloat = 0
    /// How far the axis of the system's column (clock, Wi-Fi) lies from the
    /// strip's centre; 0 where nothing is there.
    var axisShift: CGFloat = 0
}

/// Cuts the library at the edge of the side column only: where the tabs
/// stand at the side, nothing is drawn past the content's edge there; top,
/// bottom and the other side stay open (backgrounds under the status bar and
/// the bottom bar). With the tabs at the bottom it cuts nothing.
nonisolated struct SideColumnClip: Shape {
    let placement: TabBarPlacement

    func path(in rect: CGRect) -> Path {
        let open: CGFloat = 10_000
        switch placement {
        case .bottom:
            return Path(rect.insetBy(dx: -open, dy: -open))
        case .side(.trailing):
            return Path(CGRect(x: rect.minX - open, y: rect.minY - open,
                               width: rect.width + open, height: rect.height + 2 * open))
        case .side(.leading):
            return Path(CGRect(x: rect.minX, y: rect.minY - open,
                               width: rect.width + open, height: rect.height + 2 * open))
        }
    }
}

/// Apple's way for a bar of our own: the window's occlusion regions
/// (`UIView.reservedRegions`, iOS 27.1), read whenever the window lays out.
private struct ReservedStripReader: UIViewRepresentable {
    let stripWidth: CGFloat
    @Binding var reading: ReservedStrip

    func makeUIView(context: Context) -> ReaderView { ReaderView() }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.stripWidth = stripWidth
        view.report = { value in if reading != value { reading = value } }
        view.setNeedsLayout()
    }

    final class ReaderView: UIView {
        var stripWidth: CGFloat = 0
        var report: ((ReservedStrip) -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let window, stripWidth > 0 else { return }
            var value = ReservedStrip()
            if #available(iOS 27.1, *) {
                let strip = CGRect(x: window.bounds.maxX - stripWidth, y: 0,
                                   width: stripWidth, height: window.bounds.height)
                let regions = window.reservedRegions(kind: .occlusion)
                    .filter { $0.isActive && $0.frame.intersects(strip) }
                value.top = regions.map(\.frame.maxY).max() ?? 0
                // The axis: the status column is the widest region in the
                // strip; its glyphs stand on `StatusColumnAxis`.
                if let column = regions.max(by: { $0.frame.width < $1.frame.width }) {
                    value.axisShift = StatusColumnAxis.x(columnMinX: column.frame.minX,
                                                         columnWidth: column.frame.width) - strip.midX
                }
            }
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
