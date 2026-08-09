// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Persistent bar at the bottom of the screen while playback is active. Floats
/// as a rounded capsule with a margin to the screen edges — modeled on Apple's
/// current "Liquid Glass" design (iOS 26), with a material fallback for older iOS
/// versions.
struct MiniPlayerBar: View {
    @ObservedObject var coordinator: PlayerCoordinator
    /// Hitch fix (second-tick): the BAR no longer observes the player — every
    /// published tick (currentTime, once per second) used to re-commit the whole
    /// glass surface (measured: one dropped frame ~1×/s while scrolling). The
    /// dynamic pieces live in SMALL observing children (`MiniPlayerSubtitle`,
    /// `MiniPlayerRing`, `MiniPlayerTransport`) — the reliable-updates lesson
    /// (observe the view model directly, not just the coordinator) moves into
    /// those children unchanged.
    let viewModel: PlayerViewModel
    let item: LibraryItem
    /// Compact mode of the collapsed bottom zone: AirPlay is dropped (space).
    var compact: Bool = false
    /// Opens the full player. Passed in as a callback instead of an own
    /// NavigationLink, because this bar (deliberately, so it stays visible on
    /// every level) hangs outside the NavigationStack and a NavigationLink would
    /// find no stack to navigate there.
    let onOpenPlayer: () -> Void
    /// Native glass-morph identity when hosted in the bottom-bar container.
    var glassMorphID: String? = nil
    var glassMorphNamespace: Namespace.ID? = nil

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
                        // 71b277f Mini 1: display-name parity — the trim
                        // from e4a0822 applies to the mini bar too (pipe/
                        // codec junk never reaches ANY surface).
                        Text(item.id.hasPrefix("radio:")
                             ? RadioMapping.displayName(item.title)
                             : item.title)
                            .font(.body).bold()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(.primary)
                        MiniPlayerSubtitle(viewModel: viewModel)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(item.title))
            .accessibilityHint(Text("Opens the player"))

            MiniPlayerTransport(viewModel: viewModel,
                                showsSkip: showExtendedControls && !isCompactPortrait,
                                showsAirPlay: !compact && (showExtendedControls || isCompactPortrait))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .modifier(AdaptiveGlassBackground(
            shape: shape, tier: .glass,
            morphID: glassMorphID, morphNamespace: glassMorphNamespace))
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

    /// Cover with the observing progress ring child around it.
    private var coverWithProgressRing: some View {
        MiniPlayerRing(viewModel: viewModel, itemId: item.id)
    }
}

/// Per-second dynamic subtitle (chapter — remaining / time / sleep timer) —
/// the ONLY text that changes every tick, isolated so the tick re-renders this
/// tiny view instead of the whole glass bar.
private struct MiniPlayerSubtitle: View {
    @ObservedObject var viewModel: PlayerViewModel

    var body: some View {
        if let chapter = viewModel.currentChapter {
            HStack(spacing: 4) {
                if let sleep = viewModel.sleepTimerRemaining {
                    // Active sleep timer, visible without opening the player.
                    Label(Self.shortTimer(sleep), systemImage: "moon.zzz.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(AppTheme.accent)
                        .monospacedDigit()
                }
                Text("\(chapter.title) — \(remainingText)")
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else if viewModel.isLiveStream {
            // 71b277f Mini 2: "03:42 / 03:42" is nonsense for a stream — the
            // shared LIVE marker plus the elapsed time (drive-mode parity).
            HStack(spacing: 6) {
                LiveBadgeInline()
                Text(Self.shortTimer(viewModel.currentTime))
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else {
            Text(timeText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private static func shortTimer(_ remaining: TimeInterval) -> String {
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

/// The LiveBadge sized for the caption line (the shared badge is caption-
/// weight already; this variant just drops the fixed white for secondary
/// surfaces — mini bar is light/dark adaptive, the player is always dark).
private struct LiveBadgeInline: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(.red).frame(width: 6, height: 6)
            Text(verbatim: "LIVE").font(.caption2.weight(.bold))
        }
    }
}

/// Progress ring + cover — the ring fraction moves with currentTime, so it
/// observes; the surrounding bar does not.
private struct MiniPlayerRing: View {
    @ObservedObject var viewModel: PlayerViewModel
    let itemId: String

    var body: some View {
        let coverSize: CGFloat = 34
        // Ring as large as cover + stroke width: the inner edge of the ring thus
        // sits directly on the cover edge, with no gap in between.
        let ringSize: CGFloat = 36

        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.3), lineWidth: 2)
                .frame(width: ringSize, height: ringSize)
            Circle()
                .trim(from: 0, to: max(0.01, fraction))
                .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: ringSize, height: ringSize)
                .rotationEffect(.degrees(-90))

            CachedAsyncImage(url: AppSession.shared.coverURL(forItemId: itemId), useThumbnail: true) { image in
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
}

/// Skip/AirPlay/play cluster — observes for isPlaying and the skip-interval
/// glyphs (the reliable-updates lesson lives HERE now, not on the whole bar).
private struct MiniPlayerTransport: View {
    @ObservedObject var viewModel: PlayerViewModel
    let showsSkip: Bool
    let showsAirPlay: Bool

    var body: some View {
        // Skip buttons only when there is enough room AND not in iPhone
        // portrait — there more of the title should be visible. F2: a
        // live stream has nothing to skip into — the bar gates like the
        // full player (play/pause stays).
        if showsSkip && !viewModel.isLiveStream {
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
        if showsAirPlay {
            AirPlayButton(tintColor: .label, activeTintColor: AppTheme.accentUIColor)
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
}
