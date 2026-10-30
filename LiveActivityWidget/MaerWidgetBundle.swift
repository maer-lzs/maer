// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import WidgetKit

/// Widget bundle of the extension. This file belongs ONLY to the widget
/// extension target (see ANLEITUNG.md).
@main
struct MaerWidgetBundle: WidgetBundle {
    var body: some Widget {
        ContinueListeningWidget()
        PodcastUpNextWidget()
        ContinueListeningControl()
    }
}
