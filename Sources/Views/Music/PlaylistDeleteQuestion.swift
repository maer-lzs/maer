// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

extension View {
    /// The one question before a playlist is deleted, on its card, its
    /// album page and its own page: the deletion reaches every device, so
    /// it is asked first, in the same words everywhere.
    func asksBeforeDeletingPlaylist(isPresented: Binding<Bool>, delete: @escaping () -> Void) -> some View {
        confirmationDialog("Delete this playlist?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        }
    }
}
