// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Persistent bar at the bottom of the screen while playback is active. Floats
/// as a rounded capsule with a margin to the screen edges. Modeled on Apple's
/// current "Liquid Glass" design (iOS 26), with a material fallback for older iOS
/// versions.
struct MiniPlayerBar: View {
    @ObservedObject var coordinator: PlayerCoordinator
    /// Hitch fix (second-tick): the BAR does not observe the player. A tick
    /// once a second used to re-commit the whole glass surface (measured: one
    /// dropped frame ~1×/s while scrolling). The dynamic pieces live in SMALL
    /// observing children (`MiniPlayerLines`, `MiniPlayerRing`,
    /// `MiniPlayerTransport`); the two that show the time observe the clock
    /// (`PlaybackClock`). The reliable-updates lesson (observe the view model
    /// directly, not just the coordinator) moves into those children
    /// unchanged.
    let viewModel: PlayerViewModel
    let item: LibraryItem
    /// Compact mode of the collapsed bottom zone: AirPlay is dropped (space).
    var compact: Bool = false
    /// False while the bar holds the stopped session of a title change: its
    /// buttons would act on nothing. The bar still opens the full player,
    /// so an open that hangs leaves a way in.
    var controlsLive: Bool = true
    /// Opens the full player. Passed in as a callback instead of an own
    /// NavigationLink, because this bar (deliberately, so it stays visible on
    /// every level) hangs outside the NavigationStack and a NavigationLink would
    /// find no stack to navigate there.
    let onOpenPlayer: () -> Void
    /// Opens Up Next; the wide bar of a song offers it as a button.
    var onOpenQueue: (() -> Void)? = nil
    /// Native glass-morph identity when hosted in the bottom-bar container.
    var glassMorphID: String? = nil
    var glassMorphNamespace: Namespace.ID? = nil
    /// Beside a side column the bar takes the column's measure as its height
    /// (`TabBarPlacement.sideMeasure`, with the search on its middle): a
    /// smaller cover and buttons, both lines of text.
    var slim: Bool = false
    /// The height of the content inside the bar; the slim bar adds one point
    /// above and below to reach the column's measure.
    private var contentHeight: CGFloat { slim ? TabBarPlacement.sideMeasure - 2 : 48 }

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var measuredWidth: CGFloat = 0
    /// The bar's left edge in the window, against the fold.
    @State private var barMinX: CGFloat = 0
    /// The display's fold, where there is one (the library hands it in).
    @Environment(\.foldLine) private var foldLine
    /// A wide bar over a fold: the title ends before it (`PlaybackBarControls.titleWidth`).
    private var titleWidth: CGFloat? {
        guard !compact, PlaybackBarControls.isWide(barWidth: measuredWidth) else { return nil }
        return PlaybackBarControls.titleWidth(barMinX: barMinX, barWidth: measuredWidth,
                                              fold: foldLine.fold, leadingPadding: 12)
    }

    /// iPhone in portrait: space is tight, so the skip buttons are dropped in
    /// favor of more title text. Only AirPlay + play remain.
    private var isCompactPortrait: Bool {
        horizontalSizeClass == .compact && verticalSizeClass == .regular
    }

    /// Threshold above which there is enough room for title text AND all the
    /// extra buttons at once. Deliberately measured against the ACTUALLY
    /// available width, not the device type. In a narrow window (e.g. Split
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
            // the transport buttons. Even with a very short book title the tap
            // area stays large instead of hugging the text tightly.
            Button(action: onOpenPlayer) {
                HStack(spacing: 12) {
                    // Progress as a ring around the cover instead of a bar.
                    // Audible style, fits the rounded capsule shape more
                    // naturally than a straight line. Kept deliberately small so
                    // more room remains for the title text.
                    coverWithProgressRing
                    VStack(alignment: .leading, spacing: 2) {
                        // The RUNNING track's title comes from the
                        // SESSION (`nowPlayingTitle`. The one derivation the
                        // full player, lock screen and CarPlay already use).
                        // The item resolution is never the truth here: for a
                        // catalog id it answers a stub whose title is the
                        // placeholder, which is why the mini bar said
                        // "Unknown Title" while the full player was right.
                        // Radio trimming lives inside that derivation too.
                        // Radio: the STATION leads, the ICY announcement is
                        // the second line. `nowPlayingTitle` is the lock
                        // screen's derivation and REPLACES the station with
                        // the song once one arrives. Measured at the device:
                        // paused it read "WDR 2 Rheinland", playing only
                        // "Wir sind der Westen", so the bar lost the one name
                        // that says WHERE the sound comes from. The full
                        // player always showed both.
                        MiniPlayerLines(viewModel: viewModel, clock: viewModel.clock, coordinator: coordinator)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: contentHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(viewModel.isLiveStream
                                      ? viewModel.stationName : viewModel.nowPlayingTitle))
            .accessibilityHint(Text("Opens the player"))
            // A STABLE handle for "something is playing". The label is the
            // running title and thus both localized and content-dependent.
            // Unusable as the thing a caller looks for when it does not know
            // in advance what will play.
            .accessibilityIdentifier("mini-player")
            .frame(width: titleWidth)

            // A wide bar carries each medium's full controls, in groups set
            // apart, play last; over a fold every button stands right of it.
            if !compact && PlaybackBarControls.isWide(barWidth: measuredWidth) {
                HStack(spacing: PlaybackBarControls.groupGap) {
                    let groups = PlaybackBarControls.wide(isLive: viewModel.isLiveStream,
                                                          isMusic: viewModel.isMusicItem)
                    ForEach(groups.indices, id: \.self) { index in
                        HStack(spacing: 0) {
                            MiniPlayerTransport(viewModel: viewModel, coordinator: coordinator,
                                                showsSkip: false, showsAirPlay: false, buttonHeight: contentHeight,
                                                controls: groups[index], onOpenQueue: onOpenQueue)
                        }
                    }
                }
                .frame(maxWidth: titleWidth == nil ? nil : .infinity, alignment: .trailing)
                .takesInput(controlsLive)
            } else {
                MiniPlayerTransport(viewModel: viewModel, coordinator: coordinator,
                                    showsSkip: showExtendedControls && !isCompactPortrait,
                                    showsAirPlay: !compact && (showExtendedControls || isCompactPortrait),
                                    buttonHeight: contentHeight,
                                    onOpenQueue: onOpenQueue)
                .takesInput(controlsLive)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, slim ? 1 : 6)
        .modifier(AdaptiveGlassBackground(
            // Beside the side column the bar is a system bar like the
            // search next to it: the system's glass, no cover tint.
            shape: shape, tier: slim ? SideColumnStyle.tier : .glass,
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
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { barMinX = $0 }
    }

    /// Cover with the observing progress ring child around it.
    private var coverWithProgressRing: some View {
        MiniPlayerRing(viewModel: viewModel, clock: viewModel.clock, itemId: item.id,
                       coverSize: slim ? 30 : 34)
    }
}

/// The two text lines of the bar: the title, and the per-second second
/// line (chapter or artist, remaining / time / sleep timer). The ONLY text
/// that changes every tick, isolated so the tick re-renders this tiny view
/// instead of the whole glass bar. The title lives here too, because while
/// another device plays and this one stands by, the hint REPLACES the
/// standby title instead of sitting under it, and both lines then read
/// the same claim once.
private struct MiniPlayerLines: View {
    @ObservedObject var viewModel: PlayerViewModel
    /// The running time: this leaf shows it, so it observes the clock.
    @ObservedObject var clock: PlaybackClock
    /// For the one claim this device could not name after a play tap.
    @ObservedObject var coordinator: PlayerCoordinator
    /// Takeover hint: observed HERE, in the small ticking leaf.
    /// The glass bar itself never observes the claim.
    @ObservedObject private var claims = PlaybackClaimSync.shared

    /// The two lines of a shown foreign claim, resolved ONCE per render
    /// from the runner's `hint` (the runner keeps the clock, the view has
    /// none), with the bar's own title as the live-stream-aware fallback.
    private struct Hint {
        var claim: PlaybackClaim
        var lines: (title: String, subtitle: String)
    }

    var body: some View {
        let own = viewModel.isLiveStream ? viewModel.stationName : viewModel.nowPlayingTitle
        let hint: Hint? = {
            guard !viewModel.isPlaying, let foreign = claims.hint else { return nil }
            return Hint(claim: foreign,
                        lines: PlaybackClaimRules.hintLines(claim: foreign, ownTitle: own,
                                                            ownItemId: viewModel.item?.id))
        }()
        Group {
            Text(hint?.lines.title ?? own)
                .font(.body).bold()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.primary)
            secondLine(hint: hint)
        }
    }

    @ViewBuilder private func secondLine(hint: Hint?) -> some View {
        if let hint {
            // Another device plays right now, whatever it plays. Play here
            // remains possible and opens THAT episode (never a lock). The
            // title and the device's name travel in the claim; the title
            // line above shows what plays there, this line names the
            // device. An episode this device cannot name after the tap is
            // said here. ONE line, truncated once.
            Label {
                if coordinator.claimNotKnownHere == hint.claim.itemId {
                    Text("Not on this device yet: \(hint.claim.title ?? "")")
                } else {
                    Text(verbatim: hint.lines.subtitle)
                }
            } icon: {
                Image(systemName: "ipad.and.iphone")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityIdentifier("mini-foreign-playing")
        } else if let chapter = viewModel.currentChapter {
            HStack(spacing: 4) {
                if let sleep = viewModel.sleepTimerRemaining {
                    // Active sleep timer, visible without opening the player.
                    Label(Self.shortTimer(sleep), systemImage: "moon.zzz.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(AppTheme.accent)
                        .monospacedDigit()
                }
                // A song's only chapter is the song: the artist leads
                // instead, or the remaining time stands alone.
                if let lead = NowPlayingPresentation.miniLead(
                        isMusic: viewModel.isMusicItem, chapterTitle: chapter.title,
                        artist: viewModel.item?.media.metadata?.authorName) {
                    Text("\(lead) · \(remainingText)")
                        .lineLimit(1)
                } else {
                    Text(remainingText)
                        .lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else if viewModel.isLiveStream {
            // "03:42 / 03:42" is nonsense for a stream. The
            // shared LIVE marker plus the elapsed time (drive-mode parity).
            HStack(spacing: 6) {
                LiveBadgeInline()
                // What is ON AIR right now, next to the LIVE marker: the
                // station stands in the title line above, so this line
                // carries the announcement instead of only a clock. Both
                // names are visible at once, exactly as in the full player.
                if let icy = viewModel.icyNowPlaying?.title, !icy.isEmpty {
                    Text(verbatim: icy).lineLimit(1).truncationMode(.tail)
                } else {
                    Text(Self.shortTimer(clock.time))
                        .monospacedDigit()
                }
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
        DurationText.remaining(seconds: max(viewModel.duration - clock.time, 0))
    }

    private var timeText: String {
        func fmt(_ s: Double) -> String {
            guard s.isFinite, s >= 0 else { return "00:00" }
            let t = Int(s); let h = t / 3600; let m = (t % 3600) / 60; let sec = t % 60
            return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
        }
        return "\(fmt(clock.time)) / \(fmt(viewModel.duration))"
    }
}

/// The LiveBadge sized for the caption line (the shared badge is caption-
/// weight already; this variant just drops the fixed white for secondary
/// surfaces. Mini bar is light/dark adaptive, the player is always dark).
private struct LiveBadgeInline: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(.red).frame(width: 6, height: 6)
            Text(verbatim: "LIVE").font(.caption2.weight(.bold))
        }
    }
}

/// Progress ring + cover. The ring fraction moves with currentTime, so it
/// observes; the surrounding bar does not.
private struct MiniPlayerRing: View {
    @Environment(\.itemRouter) private var router
    @ObservedObject var viewModel: PlayerViewModel
    /// The ring moves with the time: this leaf observes the clock.
    @ObservedObject var clock: PlaybackClock
    let itemId: String
    var coverSize: CGFloat = 34

    var body: some View {
        // Ring as large as cover + stroke width: the inner edge of the ring thus
        // sits directly on the cover edge, with no gap in between.
        let ringSize: CGFloat = coverSize + 2

        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.3), lineWidth: 2)
                .frame(width: ringSize, height: ringSize)
            Circle()
                .trim(from: 0, to: max(0.01, fraction))
                .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: ringSize, height: ringSize)
                .rotationEffect(.degrees(-90))

            Group {
                if ItemNamespace.isRadio(itemId) {
                    // A station's picture is a chain, not an address: the
                    // curated table, the site's own icon, the favicon, and
                    // the gate that keeps a 16 px favicon off a surface.
                    // The full player has always asked `RadioArtwork`; the
                    // bar asked the favicon alone and so showed the symbol
                    // for a station whose tile carried its logo.
                    RadioArtwork(stationID: itemId,
                                 faviconURL: router.coverURL(itemId),
                                 name: viewModel.stationName,
                                 targetSide: coverSize)
                } else {
                    CachedAsyncImage(url: router.coverURL(itemId), useThumbnail: true) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Circle()
                            .fill(Color.secondary.opacity(0.15))
                            // The placeholder said BOOK for everything.
                            // A running radio stream showed a closed book. The symbol
                            // follows the item's family, from the one symbol source.
                            .overlay(Image(systemName: MediaFamily.placeholderSymbol(
                                for: itemId, markedForm: ListeningStore.startedForm(itemId)))
                                .foregroundStyle(.secondary))
                    }
                }
            }
            .frame(width: coverSize, height: coverSize)
            .clipShape(Circle())
        }
        .frame(width: ringSize, height: ringSize)
    }

    private var fraction: Double {
        guard viewModel.duration > 0 else { return 0 }
        return min(max(clock.time / viewModel.duration, 0), 1)
    }
}

/// Skip/AirPlay/play cluster. Observes for isPlaying and the skip-interval
/// glyphs (the reliable-updates lesson lives HERE now, not on the whole bar).
private struct MiniPlayerTransport: View {
    @ObservedObject var viewModel: PlayerViewModel
    let coordinator: PlayerCoordinator
    let showsSkip: Bool
    let showsAirPlay: Bool
    /// 48, or the slim bar's content height beside a side column
    /// (`MiniPlayerBar.slim`).
    var buttonHeight: CGFloat = 48
    /// One group of the wide bar (`PlaybackBarControls.wide`); nil keeps the
    /// narrow set below.
    var controls: [PlaybackBarControls.Control]? = nil
    var onOpenQueue: (() -> Void)? = nil
    private var glyph: Font { buttonHeight < 48 ? .title3 : .title2 }

    var body: some View {
        if let controls {
            ForEach(controls, id: \.self) { control in
                wideButton(control)
            }
        } else {
            narrowControls
        }
    }

    @ViewBuilder
    private var narrowControls: some View {
        if showsSkip && !viewModel.isLiveStream {
        // Skip buttons only when there is enough room AND not in iPhone
        // portrait. There more of the title should be visible. A live
        // stream has nothing to skip into. The bar gates like the
        // full player (play/pause stays).
            Button {
                viewModel.skip(by: -viewModel.skipInterval)
            } label: {
                Image(systemName: "gobackward.\(Int(viewModel.skipInterval))")
                    .font(glyph)
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: buttonHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Skip back \(Int(viewModel.skipInterval)) seconds"))

            Button {
                viewModel.skip(by: viewModel.skipInterval)
            } label: {
                Image(systemName: "goforward.\(Int(viewModel.skipInterval))")
                    .font(glyph)
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: buttonHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Skip forward \(Int(viewModel.skipInterval)) seconds"))
        }

        // Switch output route. Stays in iPhone portrait too, just a plain
        // white icon directly on the bar.
        if showsAirPlay {
            airPlayButton
        }
        playButton
    }

    private var airPlayButton: some View {
        AirPlayButton(tintColor: .label, activeTintColor: AppTheme.accentUIColor)
            .frame(width: 26, height: 26)
            .frame(width: 44, height: buttonHeight)
    }

    /// Play/pause: plain white icon, no own background. Again the same
    /// size as the other transport buttons. While another device plays
    /// something else, the tap opens that episode (the coordinator
    /// decides, one rule).
    private var playButton: some View {
        Button {
            coordinator.miniPlayTapped(viewModel)
        } label: {
            Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                .font(glyph)
                .foregroundStyle(.primary)
                .frame(width: 44, height: buttonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewModel.isPlaying ? Text("Pause") : Text("Play"))
    }

    /// One control of the wide bar, with the full player's action.
    @ViewBuilder
    private func wideButton(_ control: PlaybackBarControls.Control) -> some View {
        let skip = Int(viewModel.skipInterval)
        let keys = RemoteCommandRule.keyLabels(for: viewModel.titleStep)
        switch control {
        case .titleBack:
            barButton("backward.end.fill", label: Text(keys.back)) { viewModel.stepTitle(forward: false) }
                .disabled(viewModel.chapters.isEmpty)
                .opacity(viewModel.chapters.isEmpty ? 0.3 : 1)
        case .titleForward:
            barButton("forward.end.fill", label: Text(keys.forward)) { viewModel.stepTitle(forward: true) }
                .disabled(viewModel.chapters.isEmpty)
                .opacity(viewModel.chapters.isEmpty ? 0.3 : 1)
        case .skipBack:
            barButton("gobackward.\(skip)", label: Text("Skip back \(skip) seconds")) {
                viewModel.skip(by: -viewModel.skipInterval)
            }
        case .skipForward:
            barButton("goforward.\(skip)", label: Text("Skip forward \(skip) seconds")) {
                viewModel.skip(by: viewModel.skipInterval)
            }
        case .speed:
            SpeedMenu(viewModel: viewModel, iconOnly: true)
                .font(glyph)
                .frame(width: 44, height: buttonHeight)
        case .sleepTimer:
            SleepTimerMenu(viewModel: viewModel, iconOnly: true)
                .font(glyph)
                .frame(width: 44, height: buttonHeight)
        case .queue:
            if let onOpenQueue {
                barButton("text.line.first.and.arrowtriangle.forward", label: Text("Up Next"), action: onOpenQueue)
            }
        case .play:
            playButton
        case .airPlay:
            airPlayButton
        }
    }

    private func barButton(_ symbol: String, label: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(glyph)
                .foregroundStyle(.primary)
                .frame(width: 44, height: buttonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
