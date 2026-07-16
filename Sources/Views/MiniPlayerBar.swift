import SwiftUI

/// Persistent bar at the bottom of the screen while playback is active. Floats
/// as a rounded capsule with a margin to the screen edges — modeled on Apple's
/// current "Liquid Glass" design (iOS 26), with a material fallback for older iOS
/// versions.
struct MiniPlayerBar: View {
    @ObservedObject var coordinator: PlayerCoordinator
    /// The active player, observed directly instead of only via
    /// `coordinator.viewModel` — otherwise SwiftUI does not reliably notice
    /// changes to its own @Published values (isPlaying, currentTime, …), because
    /// `coordinator` itself only notifies when `viewModel` is completely re-SET,
    /// not when values WITHIN it change. That was why play/pause did not always
    /// toggle immediately.
    @ObservedObject var viewModel: PlayerViewModel
    /// Etappe 5: reduce the bar's Liquid Glass to a cheap material during active
    /// scrolling. `isScrolling` flips only at scroll start/stop, so this observes
    /// a boundary signal — NOT a per-frame one.
    @ObservedObject private var bottomBar = BottomBarState.shared
    let item: LibraryItem
    /// Compact mode of the collapsed bottom zone: AirPlay is dropped (space).
    var compact: Bool = false
    /// Opens the full player. Passed in as a callback instead of an own
    /// NavigationLink, because this bar (deliberately, so it stays visible on
    /// every level) hangs outside the NavigationStack and a NavigationLink would
    /// find no stack to navigate there.
    let onOpenPlayer: () -> Void

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var measuredWidth: CGFloat = 0

    /// iPhone in portrait: space is tight, so the skip buttons are dropped in
    /// favor of more title text — only AirPlay + play remain.
    private var isCompactPortrait: Bool {
        horizontalSizeClass == .compact && verticalSizeClass == .regular
    }

    /// Threshold above which there is enough room for title text AND all the
    /// extra buttons at once. Deliberately measured against the ACTUALLY
    /// available width, not the device type — in a narrow window (e.g. Split
    /// View, Stage Manager, a shrunk Mac window) an iPad would otherwise still
    /// count as "always has room", though in the concrete window it does not.
    private let extendedControlsThreshold: CGFloat = 360

    private var showExtendedControls: Bool {
        measuredWidth == 0 || measuredWidth >= extendedControlsThreshold
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 30, style: .continuous)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // The tap area deliberately fills the whole available space up to
            // the transport buttons — even with a very short book title the tap
            // area stays large instead of hugging the text tightly.
            Button(action: onOpenPlayer) {
                HStack(spacing: 12) {
                    // Progress as a ring around the cover instead of a bar —
                    // Audible style, fits the rounded capsule shape more
                    // naturally than a straight line. Kept deliberately small so
                    // more room remains for the title text.
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

            // Skip buttons only when there is enough room AND not in iPhone
            // portrait — there more of the title should be visible.
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

            // Switch output route — stays in iPhone portrait too, just a plain
            // white icon directly on the bar.
            if !compact && (showExtendedControls || isCompactPortrait) {
                AirPlayButton(tintColor: .label, activeTintColor: UIColor(AppTheme.accent))
                    .frame(width: 26, height: 26)
                    .frame(width: 44, height: 48)
            }

            // Play/pause: plain white icon, no own background — again the same
            // size as the other transport buttons.
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
        .modifier(AdaptiveGlassBackground(shape: shape, reduced: bottomBar.isScrolling))
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

    /// Cover with a thin circular progress ring — sits at the edge AROUND the
    /// cover (ring slightly larger than the cover), not as a smaller circle on
    /// top.
    private var coverWithProgressRing: some View {
        let coverSize: CGFloat = 34
        // Ring as large as cover + stroke width: the inner edge of the ring thus
        // sits directly on the cover edge, with no gap in between.
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
