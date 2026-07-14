import SwiftUI

/// Small circular download indicator that copes with an unknown total size:
/// a determinate ring for a real fraction, an indeterminate spinner for the
/// sentinel -1 (server sent no Content-Length). Used by the download controls
/// so a size-less transfer no longer shows a permanently empty ring.
struct DownloadRing: View {
    let fraction: Double

    var body: some View {
        Group {
            if fraction < 0 {
                ProgressView()
            } else {
                ProgressView(value: fraction).progressViewStyle(.circular)
            }
        }
        .scaleEffect(0.7)
    }
}
