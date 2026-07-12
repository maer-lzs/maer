import UIKit

/// Small central helper for haptic feedback. Deliberately subtle (a light
/// impulse) so play/pause and chapter jumps feel "premium" without being
/// intrusive.
enum Haptics {
    @MainActor
    static func tap() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }
}
