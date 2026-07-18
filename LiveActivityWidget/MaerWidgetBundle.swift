import SwiftUI
import WidgetKit

/// Widget bundle of the extension. This file belongs ONLY to the widget
/// extension target (see ANLEITUNG.md).
@main
struct MaerWidgetBundle: WidgetBundle {
    var body: some Widget {
        ContinueListeningWidget()
        PodcastUpNextWidget()
    }
}
