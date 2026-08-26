// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// THE switch of this app — a `Toggle` that carries the system's on
/// colour instead of the brand accent.
///
/// **Why a shared BUILDING BLOCK and not a shared STATE.** The obvious route is
/// one line at the root (`.toggleStyle(…)`, or the UIKit appearance proxy), and
/// the order asked for exactly that: one place, not 53. Both were built and
/// both were MEASURED not to arrive — a screenshot of the running app still
/// showed anthracite switches in Settings. Settings live in a SHEET, and a
/// sheet is its own presentation host; only a `.tint` on the toggle itself
/// reached the control (verified with a red probe and a pixel read).
///
/// So "one place" is kept where it can be kept: one TYPE, used everywhere, with
/// a source fence that no bare `Toggle` slips back in. An environment value
/// that silently fails to reach half the app is not one place — it only looks
/// like one.
///
/// **Why not the accent.** A capsule shows a CHOICE among visible alternatives;
/// there the accent works, because the alternatives calibrate it. A switch shows
/// a two-valued state with nothing to compare against — and grey is the colour
/// iOS uses for *inactive* everywhere else, so a grey ON reads as OFF. That is
/// a statement about HUE, not about contrast ratio: measured on the user'
/// screen, the anthracite ON track sits at 3,65:1 against the OFF track and the
/// system green at 2,90:1. The number does not decide this; the meaning does.
struct AppSwitch<Label: View>: View {
    private let isOn: Binding<Bool>
    private let label: Label

    init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {
        self.isOn = isOn
        self.label = label()
    }

    var body: some View {
        Toggle(isOn: isOn) { label }
            .tint(AppTheme.switchOn)
    }
}

extension AppSwitch where Label == Text {
    init(_ title: LocalizedStringKey, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { Text(title) }
    }

    init(verbatim title: String, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { Text(verbatim: title) }
    }
}
