import SwiftUI

/// Persistente Leiste am unteren Bildschirmrand, solange eine Wiedergabe
/// aktiv ist. Schwebt als abgerundete Kapsel mit Rand zu den Bildschirm-
/// kanten — angelehnt an Apples aktuelles "Liquid Glass"-Design (iOS 26),
/// mit einem Material-Rückfallnetz für ältere iOS-Versionen.
struct MiniPlayerBar: View {
    @ObservedObject var coordinator: PlayerCoordinator
    /// Der aktive Player, direkt als beobachtetes Objekt statt nur über
    /// `coordinator.viewModel` gelesen — sonst bemerkt SwiftUI Änderungen an
    /// dessen eigenen @Published-Werten (isPlaying, currentTime, …) nicht
    /// zuverlässig, weil `coordinator` selbst nur benachrichtigt, wenn
    /// `viewModel` komplett neu GESETZT wird, nicht wenn sich Werte DARIN
    /// ändern. Das war der Grund, warum Play/Pause nicht immer sofort
    /// umgeschaltet hat.
    @ObservedObject var viewModel: PlayerViewModel
    let item: LibraryItem
    /// Kompakt-Modus der eingeklappten Bottom-Zone: AirPlay entfällt (Platz).
    var compact: Bool = false
    /// Öffnet den vollen Player. Kommt als Callback rein statt als eigener
    /// NavigationLink, weil diese Leiste (bewusst, damit sie auf jeder Ebene
    /// sichtbar bleibt) außerhalb des NavigationStack hängt und ein
    /// NavigationLink dort keinen Stack zum Navigieren finden würde.
    let onOpenPlayer: () -> Void

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var measuredWidth: CGFloat = 0

    /// iPhone im Hochformat: dort ist der Platz knapp, deshalb entfallen die
    /// Skip-Buttons zugunsten von mehr Titeltext — nur AirPlay + Play bleiben.
    private var isCompactPortrait: Bool {
        horizontalSizeClass == .compact && verticalSizeClass == .regular
    }

    /// Schwellenwert, ab dem genug Platz für Titeltext UND alle Zusatz-
    /// Buttons gleichzeitig da ist. Bewusst an der TATSÄCHLICH verfügbaren
    /// Breite gemessen, nicht am Geräte-Typ — in einem schmalen Fenster
    /// (z. B. Split View, Stage Manager, ein verkleinertes Mac-Fenster) gilt
    /// ein iPad sonst weiterhin als "hat immer Platz", obwohl es das im
    /// konkreten Fenster gerade nicht hat.
    private let extendedControlsThreshold: CGFloat = 360

    private var showExtendedControls: Bool {
        measuredWidth == 0 || measuredWidth >= extendedControlsThreshold
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 30, style: .continuous)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Der Klickbereich füllt bewusst den gesamten verfügbaren Platz
            // bis zu den Transport-Buttons — auch bei einem sehr kurzen
            // Buchtitel bleibt der Tippbereich groß, statt sich eng um den
            // Text zu ziehen.
            Button(action: onOpenPlayer) {
                HStack(spacing: 12) {
                    // Fortschritt als Ring ums Cover statt als Balken — im
                    // Audible-Stil, passt sich der abgerundeten Kapselform
                    // natürlicher an als eine gerade Linie. Bewusst kleiner
                    // gehalten, damit mehr Platz für den Titeltext bleibt.
                    coverWithProgressRing
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.body).bold()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(.primary)
                        if let chapter = viewModel.currentChapter {
                            HStack(spacing: 4) {
                                if let sleep = viewModel.sleepTimerRemaining {
                                    // Active sleep timer, visible without opening the player.
                                    Label(shortTimer(sleep), systemImage: "moon.zzz.fill")
                                        .labelStyle(.titleAndIcon)
                                        .foregroundStyle(AppTheme.accent)
                                        .monospacedDigit()
                                }
                                Text("\(chapter.title) — \(remainingText)")
                                    .lineLimit(1)
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        } else {
                            Text(timeText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(item.title))
            .accessibilityHint(Text("Opens the player"))

            // Skip-Buttons nur, wenn genug Platz ist UND nicht im iPhone-
            // Hochformat — dort soll mehr Titel sichtbar sein.
            if showExtendedControls && !isCompactPortrait {
                Button {
                    viewModel.skip(by: -viewModel.skipInterval)
                } label: {
                    Image(systemName: "gobackward.\(Int(viewModel.skipInterval))")
                        .font(.title2)
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Skip back \(Int(viewModel.skipInterval)) seconds"))

                Button {
                    viewModel.skip(by: viewModel.skipInterval)
                } label: {
                    Image(systemName: "goforward.\(Int(viewModel.skipInterval))")
                        .font(.title2)
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Skip forward \(Int(viewModel.skipInterval)) seconds"))
            }

            // Ausgabequelle wechseln — bleibt auch im iPhone-Hochformat, nur
            // ein schlichtes weißes Icon direkt auf der Leiste.
            if !compact && (showExtendedControls || isCompactPortrait) {
                AirPlayButton(tintColor: .label, activeTintColor: UIColor(AppTheme.accent))
                    .frame(width: 26, height: 26)
                    .frame(width: 44, height: 48)
            }

            // Play/Pause: schlichtes weißes Icon, kein eigener Hintergrund —
            // wieder dieselbe Größe wie die anderen Transport-Buttons.
            Button {
                viewModel.togglePlayPause()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.isPlaying ? Text("Pause") : Text("Play"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .modifier(AdaptiveGlassBackground(shape: shape))
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { measuredWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, newWidth in
                        measuredWidth = newWidth
                    }
            }
        )
    }

    /// Cover mit dünnem, kreisförmigem Fortschrittsring — liegt am Rand UMS
    /// Cover herum (Ring etwas größer als das Cover), nicht als kleinerer
    /// Kreis darüber.
    private var coverWithProgressRing: some View {
        let coverSize: CGFloat = 34
        // Ring so groß wie Cover + Strichstärke: die Innenkante des Rings liegt
        // damit direkt auf der Coverkante, ohne Spalt dazwischen.
        let ringSize: CGFloat = 36

        return ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.3), lineWidth: 2)
                .frame(width: ringSize, height: ringSize)
            Circle()
                .trim(from: 0, to: max(0.01, fraction))
                .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: ringSize, height: ringSize)
                .rotationEffect(.degrees(-90))

            CachedAsyncImage(url: AppSession.shared.coverURL(forItemId: item.id), useThumbnail: true) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Circle()
                    .fill(Color.secondary.opacity(0.15))
                    .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
            }
            .frame(width: coverSize, height: coverSize)
            .clipShape(Circle())
        }
        .frame(width: ringSize, height: ringSize)
    }

    private var fraction: Double {
        guard viewModel.duration > 0 else { return 0 }
        return min(max(viewModel.currentTime / viewModel.duration, 0), 1)
    }

    private func shortTimer(_ remaining: TimeInterval) -> String {
        let m = Int(remaining) / 60, s = Int(remaining) % 60
        return String(format: "%d:%02d", m, s)
    }

    private var remainingText: String {
        let remaining = max(viewModel.duration - viewModel.currentTime, 0)
        let totalMinutes = Int(remaining) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? String(localized: "\(hours) hr \(minutes) min left") : String(localized: "\(minutes) min left")
    }

    private var timeText: String {
        func fmt(_ s: Double) -> String {
            guard s.isFinite, s >= 0 else { return "00:00" }
            let t = Int(s); let h = t / 3600; let m = (t % 3600) / 60; let sec = t % 60
            return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
        }
        return "\(fmt(viewModel.currentTime)) / \(fmt(viewModel.duration))"
    }
}
