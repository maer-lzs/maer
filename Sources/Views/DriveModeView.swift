// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Drive-mode LAYOUT — a variant of the full player over the SAME view model
/// (no duplicated playback state). Glanceable, not readable: huge center
/// play/pause, big ±skip left/right, two lines of text max, a thin
/// NON-scrubbable progress bar, a clear exit. Deliberately absent: library,
/// search, lists, queue, chapter list, settings, glass effects (glare +
/// render cost). Sleep timer removed by decision (0693e05) — it stays in the
/// normal full player. 9941a9a: the cover is shown (portrait above the
/// title, landscape left of the controls — variant A behind the DEBUG flag
/// `-uitest-drivecover-element`; variant B — darkened full background — is
/// the DEFAULT on probation per c7185db). Dark, maximum contrast, portrait AND landscape, media-type
/// neutral; the transport row SCALES to fit portrait widths (it used to
/// overflow: 110+180+110 + spacing = 464 pt row on a ~345 pt column).
struct DriveModeView: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject var controller = DriveModeController.shared
    @ObservedObject var libraryViewModel: LibraryViewModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // 9941a9a variant B: the cover as a darkened full background —
            // content and button sizes stay EXACTLY as in variant A.
            if coverAsBackground, coordinator.activeItem != nil {
                CachedAsyncImage(url: coverURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Color.black }
                .ignoresSafeArea()
                // Kontrast-Absicherung (c7185db): strong enough for ANY
                // bright cover — worst case pure-white artwork still leaves
                // the white glyphs ≥ ~4.5:1. Glanceability beats aesthetics.
                .overlay(Color.black.opacity(0.8).ignoresSafeArea())
                .accessibilityHidden(true)
            }
            if let vm = coordinator.viewModel, coordinator.activeItem != nil {
                playback(vm)
            } else {
                idleTiles
            }
            // Auto-dim after ~30 s: an own overlay, lifted by any tap.
            if controller.dimmed {
                Color.black.opacity(0.75)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { controller.touched() })
        .overlay(alignment: .topTrailing) { exitButton }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .animation(.easeInOut(duration: 0.4), value: controller.dimmed)
    }

    // MARK: - Playback layout

    /// ENTSCHEID c7185db (the owner 02.08.): variant B — cover as darkened
    /// full background — is the DEFAULT, explicitly ON PROBATION (the sim
    /// shots had no real artwork). Variant A (cover as element) stays behind
    /// the DEBUG flag until the device verdict; then the loser leaves.
    private var coverAsBackground: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitest-drivecover-element") { return false }
        #endif
        return true
    }

    private var coverURL: URL? {
        coordinator.activeItem.flatMap { AppSession.shared.coverURL(forItemId: $0.id) }
    }

    private func playback(_ vm: PlayerViewModel) -> some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            // 9941a9a variant A (landscape): the cover sits LEFT of the
            // button field — its width comes off the controls' budget.
            let coverSide = landscape && !coverAsBackground
                ? min(geo.size.height - 48, 200) : 0
            let scale = DriveModeView.transportScale(
                availableWidth: geo.size.width - 48 - (coverSide > 0 ? coverSide + 24 : 0),
                landscape: landscape)
            HStack(spacing: 24) {
                if coverSide > 0 { coverView(side: coverSide) }
                VStack(spacing: landscape ? 10 : 20) {
                    Spacer(minLength: 0)
                    if !landscape, !coverAsBackground {
                        // Variant A (portrait): cover top-center above the title
                        // — the slot freed by the removed sleep button; the
                        // transport surfaces do NOT shrink for it.
                        coverView(side: min(geo.size.width * 0.38, 160))
                    }
                    titleBlock(vm)
                    transport(vm, landscape: landscape, scale: scale)
                    progressBar(vm)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The cover as a rounded tile (variant A). Decorative — no tap target.
    private func coverView(side: CGFloat) -> some View {
        CachedAsyncImage(url: coverURL) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.08))
                .overlay(Image(systemName: "music.note").font(.largeTitle)
                    .foregroundStyle(.white.opacity(0.4)))
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityHidden(true)
    }

    private func titleBlock(_ vm: PlayerViewModel) -> some View {
        VStack(spacing: 4) {
            Text(coordinator.activeItem?.title ?? "")
                .font(.title.weight(.bold))
                .lineLimit(1)
            if let chapter = vm.currentChapter?.title {
                Text(chapter)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
    }

    private func transport(_ vm: PlayerViewModel, landscape: Bool, scale: CGFloat) -> some View {
        HStack(spacing: (landscape ? 60 : 32) * scale) {
            skipButton(vm, forward: false, scale: scale)
            Button {
                vm.togglePlayPause()
                controller.touched()
            } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: (landscape ? 84 : 96) * scale, weight: .heavy))
                    .frame(width: (landscape ? 160 : 180) * scale,
                           height: (landscape ? 160 : 180) * scale)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .accessibilityIdentifier("drive-play-pause")
            skipButton(vm, forward: true, scale: scale)
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }

    private func skipButton(_ vm: PlayerViewModel, forward: Bool, scale: CGFloat) -> some View {
        Button {
            vm.skip(by: forward ? vm.skipInterval : -vm.skipInterval)
            controller.touched()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: forward ? "goforward" : "gobackward")
                    .font(.system(size: 52 * scale, weight: .semibold))
                Text(verbatim: "\(Int(vm.skipInterval))")
                    .font(.headline.monospacedDigit())
            }
            .frame(width: 110 * scale, height: 110 * scale)
            .background(Color.white.opacity(0.08), in: Circle())
        }
        .accessibilityIdentifier(forward ? "drive-skip-forward" : "drive-skip-back")
    }

    /// Pure (tested): shrink factor so the three-button transport row FITS the
    /// available column width in BOTH orientations (it overflowed portrait
    /// phones before — 464 pt row on a ~345 pt column ⇒ clipped skip buttons).
    /// 1.0 when the natural sizes fit; never below 0.55 (the tap surfaces
    /// stay ≥ 60 pt — glanceable minimum on every supported phone).
    nonisolated static func transportScale(availableWidth: CGFloat, landscape: Bool) -> CGFloat {
        guard availableWidth > 0 else { return 1 }
        let play: CGFloat = landscape ? 160 : 180
        let spacing: CGFloat = landscape ? 60 : 32
        let needed = play + 2 * 110 + 2 * spacing
        guard needed > availableWidth else { return 1 }
        return max(availableWidth / needed, 0.55)
    }

    /// Thin, NOT scrubbable — aiming at a bar while driving is an illusion.
    private func progressBar(_ vm: PlayerViewModel) -> some View {
        VStack(spacing: 6) {
            ProgressView(value: vm.duration > 0 ? min(max(vm.currentTime / vm.duration, 0), 1) : 0)
                .tint(.white)
            Text(remainingText(vm))
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 12)
    }

    private func remainingText(_ vm: PlayerViewModel) -> String {
        let remaining = max(vm.duration - vm.currentTime, 0)
        let h = Int(remaining) / 3600, m = (Int(remaining) % 3600) / 60
        return h > 0 ? "-\(h):\(String(format: "%02d", m)) h" : "-\(m) min"
    }

    // MARK: - Idle: continue tiles (only when nothing plays)

    private var idleTiles: some View {
        VStack(spacing: 16) {
            Text("Continue Listening")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
            ForEach(libraryViewModel.continueListening.prefix(3)) { entry in
                Button {
                    Task { await coordinator.open(item: entry.item) }
                    controller.touched()
                } label: {
                    Text(entry.item.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 88)
                        .background(Color.white.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            if libraryViewModel.continueListening.isEmpty {
                Text("Nothing in progress.")
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(24)
    }

    private var exitButton: some View {
        Button {
            DriveModeController.shared.exit()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Color.white.opacity(0.12), in: Circle())
                .padding()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("drive-exit")
    }
}
