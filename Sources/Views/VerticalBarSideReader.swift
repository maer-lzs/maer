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
    /// The reader is a UIView behind a column that spans the whole window,
    /// so it never takes a touch: a UIView takes touches by default, and
    /// over the whole window it would cover every card and tile.
    func readsReservedStrip(ofWidth width: CGFloat, _ reading: Binding<ReservedStrip>) -> some View {
        background {
            ReservedStripReader(stripWidth: width, reading: reading)
                .takesInput(false)
        }
    }
}

/// What the system reserves in the side strip, in window points.
struct ReservedStrip: Equatable {
    /// How far down the reserved regions reach; 0 where nothing is there.
    var top: CGFloat = 0
    /// How far the axis of the system's column (clock, Wi-Fi) lies from the
    /// strip's centre; 0 where nothing is there.
    var axisShift: CGFloat = 0
    /// The window's trailing edge in window points.
    var windowMaxX: CGFloat = 0
    /// Where the system says a page should divide in two (the fold of an
    /// open foldable), in window points; nil where there is none.
    var division: CGRect?

    /// The column's shift from the middle of its strip onto the axis, for a
    /// strip whose trailing edge lies at `stripMaxX` in window points: the
    /// axis is reckoned from the window's edge, and a sheet's strip ends
    /// short of it (8 pt in the settings, measured on the folded Duo).
    func shift(stripMaxX: CGFloat) -> CGFloat {
        guard windowMaxX > 0, stripMaxX > 0 else { return axisShift }
        return axisShift + (windowMaxX - stripMaxX)
    }
}

extension EnvironmentValues {
    /// How far the side column reaches over the content's trailing edge:
    /// 0 with the tabs at the bottom.
    @Entry var sideColumnReach: CGFloat = 0
    /// Where a two-column page divides (`FoldSplit`): set by the library.
    @Entry var foldLine = FoldLine()
}

/// The fold the system names, if any, and the window's width, both in
/// window points: what `FoldSplit` needs from outside the page.
struct FoldLine: Equatable {
    var fold: ClosedRange<CGFloat>?
    var windowWidth: CGFloat = 0
}

extension View {
    /// THE way a horizontal row draws past its frame (`scrollClipDisabled`).
    /// Beside a side column it runs under the column to the window's edge
    /// and ends with a margin of the column's width, so at rest nothing one
    /// taps stands behind the column.
    func rowReachesUnderSideColumn() -> some View {
        modifier(RowUnderSideColumn())
    }
}

private struct RowUnderSideColumn: ViewModifier {
    @Environment(\.sideColumnReach) private var reach

    func body(content: Content) -> some View {
        content
            .scrollClipDisabled()
            .contentMargins(.trailing, reach, for: .scrollContent)
            .padding(.trailing, -reach)
    }
}

/// Apple's way for a bar of our own: the window's occlusion regions
/// (`UIView.reservedRegions`, iOS 27.1), read whenever the window lays out.
private struct ReservedStripReader: UIViewRepresentable {
    let stripWidth: CGFloat
    @Binding var reading: ReservedStrip

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        return view
    }

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
            value.windowMaxX = window.bounds.maxX
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
                // The fold of the open Duo: inactive while the device lies
                // flat open (measured), and still where the page divides.
                value.division = window.reservedRegions(kind: .division, options: .includeInactive).first?.frame
            }
            // After the layout pass, not inside it: the report writes view state.
            Task { [report] in report?(value) }
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
        /// The safe area at the window's edges: the column the system keeps
        /// free at its edge, if any.
        @State private var insets = EdgeInsets()

        private var systemEdge: VerticalBarSide? {
            switch edge {
            case .leading: .leading
            case .trailing: .trailing
            case nil: nil
            }
        }

        private var freeColumn: CGFloat {
            systemEdge == .leading ? insets.leading : insets.trailing
        }

        var body: some View {
            Color.clear
                .accessibilityHidden(true)
                .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets = $0 }
                .onChange(of: [systemEdge.map { "\($0)" } ?? "", "\(freeColumn)"], initial: true) {
                    side = TabBarPlacement.side(systemEdge: systemEdge, freeColumn: freeColumn)
                }
        }
    }
}
