// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import UIKit

/// The chosen appearance, applied where it is needed.
///
/// The choice is set on the app's windows, and every sheet and full-screen
/// cover takes it from its window. `preferredColorScheme` is no way for
/// it: a sheet is a presentation host of its own, and its nil after Light
/// or Dark left an open sheet in the former scheme, deaf to the system's
/// switch. The root and every presented leaf carry this modifier, so a new
/// window takes the choice when its root reaches it.
struct AppearanceHost: ViewModifier {
    @AppStorage(AppStorageKeys.appearance) private var appearance = AppearanceChoice.system.rawValue

    func body(content: Content) -> some View {
        content
            .background(WindowStyle(style: Self.style(AppearanceChoice.of(appearance))))
            // A presentation host does not inherit this.
            .noScrollBars()
    }

    /// The choice as the window's style; unspecified follows the system.
    nonisolated static func style(_ choice: AppearanceChoice) -> UIUserInterfaceStyle {
        switch choice {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Sets a style on every window of the scene it stands in, when the style
/// changes and when it reaches its window. The car's scene draws no
/// SwiftUI view and follows the car.
private struct WindowStyle: UIViewRepresentable {
    let style: UIUserInterfaceStyle

    func makeUIView(context: Context) -> Setter { Setter() }

    func updateUIView(_ view: Setter, context: Context) {
        view.style = style
    }

    final class Setter: UIView {
        var style: UIUserInterfaceStyle = .unspecified {
            didSet { apply() }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        private func apply() {
            for window in window?.windowScene?.windows ?? [] where window.overrideUserInterfaceStyle != style {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}

extension View {
    /// Makes this view follow the chosen appearance. Belongs on the app's
    /// root and on the content of every sheet and full-screen cover; a leaf
    /// that deliberately keeps its own scheme (drive mode is always dark)
    /// stands in the fence's exception list instead.
    func followsAppearanceChoice() -> some View {
        modifier(AppearanceHost())
    }

    /// THE one place for scroll bars: the app shows none, on every device
    /// and in every posture. The root and every presented leaf carry it
    /// with the appearance (`followsAppearanceChoice`); a leaf that keeps
    /// its own scheme carries it itself. `.never`, not `.hidden`: hidden is
    /// a wish the Mac overrules with a mouse or with "Show scroll bars:
    /// Always", and the bars stood there.
    func noScrollBars() -> some View {
        scrollIndicators(.never)
    }
}
