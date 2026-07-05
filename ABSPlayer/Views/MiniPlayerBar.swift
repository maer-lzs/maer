import SwiftUI

/// Persistente Leiste am unteren Bildschirmrand, solange eine Wiedergabe
/// aktiv ist. Etwas größer als eine minimale Leiste, mit Cover, Titel,
/// aktuellem Kapitel, dünnem Fortschrittsbalken und ±30s/Play-Pause.
struct MiniPlayerBar: View {
    @ObservedObject var coordinator: PlayerCoordinator
    /// Öffnet den vollen Player. Kommt als Callback rein statt als eigener
    /// NavigationLink, weil diese Leiste (bewusst, damit sie auf jeder Ebene
    /// sichtbar bleibt) außerhalb des NavigationStack hängt und ein
    /// NavigationLink dort keinen Stack zum Navigieren finden würde.
    let onOpenPlayer: () -> Void

    var body: some View {
        if let viewModel = coordinator.viewModel, let item = coordinator.activeItem {
            VStack(spacing: 0) {
                Divider()

                // Dünner Fortschrittsbalken ganz oben in der Leiste.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.2))
                        Rectangle()
                            .fill(AppTheme.accent)
                            .frame(width: geo.size.width * fraction(viewModel))
                    }
                }
                .frame(height: 2)

                HStack(spacing: 12) {
                    Button {
                        coordinator.close()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(6)
                    }
                    .buttonStyle(.plain)

                    Button(action: onOpenPlayer) {
                        HStack(spacing: 12) {
                            BookCoverView(
                                url: coordinator.apiClient.coverURL(forItemId: item.id),
                                progress: nil,
                                size: 48
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.subheadline).bold()
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                                if let chapter = viewModel.currentChapter {
                                    Text(chapter.title)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                } else {
                                    Text(timeText(viewModel))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        viewModel.skip(by: -30)
                    } label: {
                        Image(systemName: "gobackward.30").font(.title3)
                    }
                    .buttonStyle(.plain)

                    Button {
                        viewModel.togglePlayPause()
                    } label: {
                        Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(AppTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(.bar)
        }
    }

    private func fraction(_ vm: PlayerViewModel) -> Double {
        guard vm.duration > 0 else { return 0 }
        return min(max(vm.currentTime / vm.duration, 0), 1)
    }

    private func timeText(_ vm: PlayerViewModel) -> String {
        func fmt(_ s: Double) -> String {
            guard s.isFinite, s >= 0 else { return "00:00" }
            let t = Int(s); let h = t / 3600; let m = (t % 3600) / 60; let sec = t % 60
            return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
        }
        return "\(fmt(vm.currentTime)) / \(fmt(vm.duration))"
    }
}
