import SwiftUI
import Combine

/// Geteilter Zustand der einklappbaren Bottom-Zone. Jede gescrollte Fläche der
/// App (Bibliothek, Podcast-Home, Detailseiten) meldet ihren Scroll-Offset über
/// `reportsBottomBarScroll()`; die `LibraryView` liest `collapsed` und baut die
/// Leiste entsprechend auf — so verhält sich der Mini-Player überall gleich.
@MainActor
final class BottomBarState: ObservableObject {
    static let shared = BottomBarState()
    private init() {}

    @Published var scrollY: CGFloat = 0
    /// Home-Tap klappt wieder auf; der nächste Scroll aktiviert das Einklappen erneut.
    @Published var forceExpanded = false

    var collapsed: Bool { scrollY > 60 && !forceExpanded }

    func report(_ y: CGFloat) {
        scrollY = y
        if forceExpanded { forceExpanded = false }
    }

    func expand() { forceExpanded = true }

    /// Beim Tab-Wechsel: aufklappen (Stale-Offset der anderen Fläche vermeiden).
    func reset() { scrollY = 0; forceExpanded = false }
}

extension View {
    /// An JEDE gescrollte Fläche hängen — meldet den Offset an die Bottom-Zone.
    func reportsBottomBarScroll() -> some View {
        onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
            BottomBarState.shared.report(y)
        }
    }
}
