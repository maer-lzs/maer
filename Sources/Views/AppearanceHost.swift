// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The chosen appearance, applied where it is needed.
///
/// `preferredColorScheme` reaches the window of the view it sits on, and a
/// sheet or a full-screen cover is a presentation host of its OWN: the
/// choice at the root never arrived there, so the app switched and the
/// settings sheet stayed with the system. Every presented leaf carries
/// this modifier, and the root carries it too, so the choice is read in
/// ONE place.
struct AppearanceHost: ViewModifier {
    @AppStorage(AppStorageKeys.appearance) private var appearance = AppearanceChoice.system.rawValue

    func body(content: Content) -> some View {
        content.preferredColorScheme(Self.scheme(AppearanceChoice.of(appearance)))
    }

    /// The choice as SwiftUI's scheme; nil follows the system.
    nonisolated static func scheme(_ choice: AppearanceChoice) -> ColorScheme? {
        switch choice {
        case .system: nil
        case .light: .light
        case .dark: .dark
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
}
