import SwiftUI

@main
struct ABSPlayerApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                // Globale Akzentfarbe der App: Orange statt System-Blau.
                .tint(AppTheme.accent)
        }
    }
}

/// Zentrale Stelle für App-weite Farben. Wenn du die Akzentfarbe ändern
/// willst, reicht es, sie hier anzupassen.
enum AppTheme {
    static let accent = Color.orange
}
