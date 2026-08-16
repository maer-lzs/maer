// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Drive-mode LAYOUT — a variant of the full player over the SAME view model
/// (no duplicated playback state). Glanceable, not readable: huge center
/// play/pause, big ±skip left/right, two lines of text max, a thin
/// NON-scrubbable progress bar, a clear exit. Deliberately absent: library,
/// search, lists, queue, chapter list, settings, glass effects (glare +
/// render cost). Sleep timer removed by decision (0693e05) — it stays in the
/// normal full player. 8d54582: the cover is the HERO — the book-detail
/// stage anatomy (shared `CoverHeroStage`), fading into the black control
/// area; ONE cover, ONE frame, the lower area never renders its own. The
/// hero height is CAPPED relative to the screen (cda2bea: 40 % portrait, 42 % landscape width) (298d6b1 — the 464-pt
/// lesson: nothing fixed that overflows the next device); the transport row
/// SCALES to fit (pure `transportScale`). Dark, maximum contrast, portrait
/// AND landscape, media-type neutral.
struct DriveModeView: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject var controller = DriveModeController.shared
    @ObservedObject var libraryViewModel: LibraryViewModel
    /// 206e552: the app-wide edge-color source (cards, book-detail hero) —
    /// ONE color derivation, never a second one for drive mode.
    @StateObject private var colorLoader = CoverColorLoader()

    var body: some View {
        ZStack {
            backdrop.ignoresSafeArea()
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
        // 206e552: the tint follows the cover — one calm crossfade per item
        // change, never a color jump mid-fade (the hero's own behaviour).
        .animation(.easeInOut(duration: 0.5), value: colorLoader.bottomAccent)
        .task(id: coordinator.activeItem?.id) {
            // A live stream has no cover to sample — its deterministic
            // placeholder tint IS the source (no side path, same rule).
            if liveItemId == nil { await colorLoader.load(from: coverURL) }
        }
    }

    /// 206e552: below the hero the standard tinted gradient instead of hard
    /// black — the color comes from the cover's BOTTOM edge (or, for radio,
    /// the station's placeholder tint). Drive-mode legibility rules: the
    /// tint is heavily darkened ("tinted darkness", never full color) so the
    /// controls keep their contrast at night.
    private var backdrop: some View {
        // Black stays the base — the tint is laid OVER it with low opacity,
        // which is exactly what makes it a darkened shade of the same hue.
        ZStack {
            Color.black
            LinearGradient(colors: [Self.driveTint(tintSource, strength: 0.34),
                                    Self.driveTint(tintSource, strength: 0.10),
                                    .clear],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    /// The hero fades into the SAME top shade the backdrop starts with —
    /// no visible seam between stage and control area.
    private var heroFade: Color {
        Self.driveTint(tintSource, strength: 0.34)
    }

    /// The tint source: the cover's bottom edge, or the station color for a
    /// live stream (which renders the placeholder hero, not a cover).
    private var tintSource: Color {
        if let id = liveItemId { return RadioArtwork.color(for: id) }
        return colorLoader.hasAccent ? colorLoader.bottomAccent : .black
    }

    /// Darkened tint: the color is kept, the light is taken away — pure
    /// opacity over black, so every derived shade stays in the SAME hue
    /// family (what the screenshot assert checks).
    static func driveTint(_ color: Color, strength: Double) -> Color {
        color.opacity(strength)
    }

    // MARK: - Playback layout

    private var coverURL: URL? {
        coordinator.activeItem.flatMap { AppSession.shared.coverURL(forItemId: $0.id) }
    }

    /// 6b3a35d: the radio branch — live items route the hero through the
    /// SAME favicon gate as player/detail and drop the pointless skips.
    private var liveItemId: String? {
        guard let id = coordinator.activeItem?.id, id.hasPrefix("radio:") else { return nil }
        return id
    }

    @ViewBuilder
    private var heroStage: some View {
        if let id = liveItemId {
            // Gate chain (Regel 2): reject → gradient+initials, never the
            // upscaled favicon mash.
            CoverHeroStage(url: nil, fadeTo: heroFade,
                           coverOverride: RadioArtwork(
                               stationID: id, faviconURL: coverURL,
                               name: coordinator.activeItem?.title ?? "",
                               isHero: true))
        } else {
            CoverHeroStage(url: coverURL, placeholderSymbol: "music.note", fadeTo: heroFade)
        }
    }

    /// 8d54582 hero layout. Portrait: the cover is a full-width STAGE at the
    /// top (book-detail anatomy via the shared `CoverHeroStage`), fading into
    /// the black control area; height capped at 32 % of the screen so the
    /// big-button field is NEVER displaced (298d6b1 — everything relative,
    /// nothing fixed). Landscape: the hero is the LEFT pane (width capped),
    /// controls keep the remaining width and scale to fit.
    private func playback(_ vm: PlayerViewModel) -> some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            if landscape {
                // cda2bea: the hero may take more room — width raised (~42 %),
                // still capped by height and always leaving the controls the
                // majority of the width (big buttons never displaced).
                let heroWidth = min(geo.size.width * 0.42, geo.size.height)
                HStack(spacing: 0) {
                    heroStage
                        .frame(width: heroWidth)
                        .ignoresSafeArea(edges: [.leading, .vertical])
                    controlsColumn(vm, landscape: true,
                                   availableWidth: geo.size.width - heroWidth - 48)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    heroStage
                        // cda2bea: portrait cap raised ~32 % → 40 % (device
                        // judgement); still relative, buttons keep their room.
                        .frame(height: min(geo.size.width, geo.size.height * 0.40))
                        .frame(maxWidth: .infinity)
                        .ignoresSafeArea(edges: .top)
                    controlsColumn(vm, landscape: false,
                                   availableWidth: geo.size.width - 48)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Title · transport · progress — shared by both orientations; the
    /// transport row scales to the width the hero leaves.
    private func controlsColumn(_ vm: PlayerViewModel, landscape: Bool,
                                availableWidth: CGFloat) -> some View {
        let scale = DriveModeView.transportScale(availableWidth: availableWidth,
                                                 landscape: landscape)
        return VStack(spacing: landscape ? 10 : 20) {
            Spacer(minLength: 0)
            titleBlock(vm)
            transport(vm, landscape: landscape, scale: scale)
            progressBar(vm)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func titleBlock(_ vm: PlayerViewModel) -> some View {
        VStack(spacing: 4) {
            // f0e7f4e sweep: ONE session source for the running title, like
            // every other now-playing surface. The live/non-live split fell
            // away with it — `nowPlayingTitle` already carries the station
            // trimming (6b3a35d) and the ICY line for streams, and the item
            // title is a stub for catalog ids.
            Text(vm.nowPlayingTitle)
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
            // 6b3a35d (2): ±skip on a LIVE stream is a lie (no seek buffer) —
            // G8: the buttons go, play/pause stays centered and the row
            // closes up (scale then resolves to 1 → the button grows).
            if liveItemId == nil { skipButton(vm, forward: false, scale: scale) }
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
            if liveItemId == nil { skipButton(vm, forward: true, scale: scale) }
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }

    private func skipButton(_ vm: PlayerViewModel, forward: Bool, scale: CGFloat) -> some View {
        Button {
            vm.skip(by: forward ? vm.skipInterval : -vm.skipInterval)
            controller.touched()
        } label: {
            Group {
                // a74c903: the standard glyph WITH the number inside the
                // arrow (gobackward.15/30/60) — hit surface unchanged, only
                // the glyph. An interval without a matching SF symbol (server-
                // side custom values) falls back to the old two-line form.
                if let glyph = DriveModeView.skipGlyphName(interval: vm.skipInterval, forward: forward) {
                    Image(systemName: glyph)
                        .font(.system(size: 56 * scale, weight: .semibold))
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: forward ? "goforward" : "gobackward")
                            .font(.system(size: 52 * scale, weight: .semibold))
                        Text(verbatim: "\(Int(vm.skipInterval))")
                            .font(.headline.monospacedDigit())
                    }
                }
            }
            .frame(width: 110 * scale, height: 110 * scale)
            .background(Color.white.opacity(0.08), in: Circle())
        }
        .accessibilityIdentifier(forward ? "drive-skip-forward" : "drive-skip-back")
    }

    /// Pure (tested): the numbered SF skip glyph, nil when SF has no symbol
    /// for the interval (then the caller keeps the two-line fallback).
    nonisolated static func skipGlyphName(interval: Double, forward: Bool) -> String? {
        let supported: Set<Int> = [5, 10, 15, 30, 45, 60, 75, 90]
        let seconds = Int(interval)
        guard Double(seconds) == interval, supported.contains(seconds) else { return nil }
        return (forward ? "goforward." : "gobackward.") + String(seconds)
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
    @ViewBuilder
    private func progressBar(_ vm: PlayerViewModel) -> some View {
        if liveItemId != nil {
            // 6b3a35d (3): "-0 min" was nonsense for a stream — the shared
            // LIVE marker plus the elapsed time (the only honest number).
            HStack(spacing: 12) {
                LiveBadge()
                Text(elapsedText(vm))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            .accessibilityIdentifier("drive-live-row")
        } else {
            VStack(spacing: 6) {
                ProgressView(value: vm.duration > 0 ? min(max(vm.currentTime / vm.duration, 0), 1) : 0)
                    .tint(.white)
                Text(remainingText(vm))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 12)
        }
    }

    private func elapsedText(_ vm: PlayerViewModel) -> String {
        let seconds = Int(max(vm.currentTime, 0))
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return h > 0 ? String(format: "%d:%02d h", h, m) : "\(m) min"
    }

    private func remainingText(_ vm: PlayerViewModel) -> String {
        let remaining = max(vm.duration - vm.currentTime, 0)
        let h = Int(remaining) / 3600, m = (Int(remaining) % 3600) / 60
        return h > 0 ? "-\(h):\(String(format: "%02d", m)) h" : "-\(m) min"
    }

    // MARK: - Idle: continue tiles (only when nothing plays)

    private var idleTiles: some View {
        VStack(spacing: 16) {
            Text("Keep Listening")
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
