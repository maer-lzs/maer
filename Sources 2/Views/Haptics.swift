import UIKit

/// Kleiner zentraler Helfer für haptisches Feedback. Bewusst dezent gehalten
/// (leichter Impuls), damit Play/Pause und Kapitelsprünge sich „wertig"
/// anfühlen, ohne aufdringlich zu sein.
enum Haptics {
    @MainActor
    static func tap() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }
}
