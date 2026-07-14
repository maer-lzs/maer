import SwiftUI

/// Small floating activity pill shown while a background reload runs with
/// content already on screen — pull-to-refresh returns early by design, so
/// without this the sync would be invisible.
struct RefreshActivityPill: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .padding(10)
            .modifier(AdaptiveGlassBackground(shape: Circle()))
            .padding(.top, 6)
            .transition(.opacity)
            .allowsHitTesting(false)
    }
}
