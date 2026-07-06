import SwiftUI

/// Zeigt kurz an, woher der Fortschritt beim Start der Wiedergabe kam
/// ("Fortgesetzt vom Server" / "Offline-Fortschritt übernommen") — schiebt
/// sich von links ein und blendet nach einigen Sekunden wieder nach links
/// aus. Eigene View mit `@ObservedObject`, damit Änderungen an
/// `resumeSourceMessage` zuverlässig ankommen — ein nur über
/// `coordinator.viewModel?.resumeSourceMessage` gelesener Wert würde nicht
/// zuverlässig aktualisieren, da `PlayerCoordinator` nur benachrichtigt, wenn
/// `viewModel` komplett neu gesetzt wird, nicht wenn sich Werte darin ändern
/// (dasselbe Muster wie beim Play/Pause-Button).
///
/// Bewusst OHNE eigenen Glas-Hintergrund: In Toolbars geben iOS-26-Elemente
/// sich automatisch ihr eigenes Liquid-Glass-Aussehen — ein zusätzlicher
/// eigener Hintergrund hier verschachtelt sich damit (dasselbe Problem wie
/// beim Sortier-Button) und machte den Text schlecht lesbar. Ein Schatten
/// sorgt stattdessen für Kontrast, unabhängig vom Hintergrund darunter.
struct ResumeMessageBanner: View {
    @ObservedObject var viewModel: PlayerViewModel

    var body: some View {
        Group {
            if let message = viewModel.resumeSourceMessage {
                Text(message)
                    .font(.caption).bold()
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 3)
                    .lineLimit(1)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.6), value: viewModel.resumeSourceMessage)
    }
}
