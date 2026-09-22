// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

extension View {
    /// The one confirmation before every download on this device is removed.
    /// The settings and the library both offer the action, so both show this
    /// alert, with one wording and one call.
    func deleteAllDownloadsAlert(isPresented: Binding<Bool>) -> some View {
        alert("Delete all downloads?", isPresented: isPresented) {
            Button("Delete", role: .destructive) {
                DownloadManager.shared.deleteAllDownloads()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All downloaded audiobooks will be removed from this device. Listening progress is kept.")
        }
    }
}
