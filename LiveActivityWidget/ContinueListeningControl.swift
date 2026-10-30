// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import AppIntents
import SwiftUI
import WidgetKit

/// Control "Continue Listening" for Control Center and the lock screen's
/// corners: one press continues the last played title, the same command as
/// the widget's play button. This file belongs ONLY to the widget extension
/// target.
struct ContinueListeningControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ContinueListeningControl") {
            ControlWidgetButton(action: ResumeListeningIntent()) {
                Label("Continue Listening", systemImage: "play.fill")
            }
        }
        .displayName("Continue Listening")
        .description("Continues the last played title.")
    }
}
