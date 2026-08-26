// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import SwiftUI
import Testing
@testable import ABSPlayer

/// Does a UIFont metric agree with what SwiftUI renders?
/// Measures every tab title at every ladder size. SwiftUI width via
/// ImageRenderer (a real render), metric width via NSAttributedString.
/// The DEVIATION is the answer the Prüfbericht needs.
@Suite struct FontMetricProbe {

    @Test func metricVersusRenderedWidth() throws {
        var worst: Double = 0
        var lines: [String] = []
        for type in MediaType.allCases {
            for size in MediaTabBar.labelSizes {
                let font = UIFont.systemFont(ofSize: size)
                let metric = (type.label as NSString).size(
                    withAttributes: [.font: font]).width
                let renderer = ImageRenderer(
                    content: Text(type.label).font(.system(size: size)).fixedSize())
                renderer.scale = 3
                guard let rendered = renderer.uiImage?.size.width else {
                    Issue.record("kein Render für \(type.label) @\(size)")
                    continue
                }
                let delta = Double(abs(rendered - metric))
                worst = max(worst, delta)
                lines.append("\(type.label) @\(size): metric=\(String(format: "%.2f", metric)) rendered=\(String(format: "%.2f", rendered)) Δ=\(String(format: "%.2f", delta))")
            }
        }
        // Measured: worst Δ = 0.32 pt over all
        // 5 titles × 7 ladder sizes. Sub-pixel rounding, systematic. The
        // record stands as a fence: if a font change ever breaks metric
        // fidelity, the self-computation debate reopens with a number.
        #expect(worst < 2.0, "Metrik weicht vom Render ab:\n\(lines.joined(separator: "\n"))")
    }
}

#endif
