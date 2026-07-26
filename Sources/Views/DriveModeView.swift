// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Drive-mode LAYOUT — a variant of the full player over the SAME view model
/// (no duplicated playback state). Glanceable, not readable: huge center
/// play/pause, big ±skip left/right, two lines of text max, a thin
/// NON-scrubbable progress bar, sleep timer as one cycling button, a clear
/// exit. Deliberately absent: library, search, lists, queue, chapter list,
/// settings, big cover, glass effects (glare + render cost). Dark, maximum
/// contrast, portrait AND landscape, media-type neutral.
struct DriveModeView: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject var controller = DriveModeController.shared
    @ObservedObject var libraryViewModel: LibraryViewModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
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

    private func playback(_ vm: PlayerViewModel) -> some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            VStack(spacing: landscape ? 10 : 24) {
                Spacer(minLength: 0)
                titleBlock(vm)
                transport(vm, landscape: landscape)
                progressBar(vm)
                sleepButton(vm)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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

    private func transport(_ vm: PlayerViewModel, landscape: Bool) -> some View {
        HStack(spacing: landscape ? 60 : 32) {
            skipButton(vm, forward: false)
            Button {
                vm.togglePlayPause()
                controller.touched()
            } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: landscape ? 84 : 96, weight: .heavy))
                    .frame(width: landscape ? 160 : 180, height: landscape ? 160 : 180)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .accessibilityIdentifier("drive-play-pause")
            skipButton(vm, forward: true)
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }

    private func skipButton(_ vm: PlayerViewModel, forward: Bool) -> some View {
        Button {
            vm.skip(by: forward ? vm.skipInterval : -vm.skipInterval)
            controller.touched()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: forward ? "goforward" : "gobackward")
                    .font(.system(size: 52, weight: .semibold))
                Text(verbatim: "\(Int(vm.skipInterval))")
                    .font(.headline.monospacedDigit())
            }
            .frame(width: 110, height: 110)
            .background(Color.white.opacity(0.08), in: Circle())
        }
        .accessibilityIdentifier(forward ? "drive-skip-forward" : "drive-skip-back")
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

    /// One button, fixed steps: off → 15 → 30 → 60 → off.
    private func sleepButton(_ vm: PlayerViewModel) -> some View {
        Button {
            let next = DriveModeView.nextSleepStep(active: vm.sleepTimerRemaining != nil,
                                                   current: vm.sleepTimerRemaining)
            if let minutes = next { vm.startSleepTimer(minutes: Double(minutes)) }
            else { vm.cancelSleepTimer() }
            controller.touched()
        } label: {
            Label(vm.sleepTimerRemaining != nil
                    ? String(localized: "Sleep timer on")
                    : String(localized: "Sleep timer"),
                  systemImage: "moon.zzz.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(vm.sleepTimerRemaining != nil ? .black : .white)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(vm.sleepTimerRemaining != nil ? Color.white : Color.white.opacity(0.12),
                            in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("drive-sleep")
    }

    /// Pure (tested): cycle off→15→30→60→off based on the running timer.
    nonisolated static func nextSleepStep(active: Bool, current: Double?) -> Int? {
        guard active, let current else { return 15 }
        let minutes = current / 60
        if minutes <= 16 { return 30 }
        if minutes <= 31 { return 60 }
        return nil
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
