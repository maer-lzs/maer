// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI


/// Full player with drag-to-dismiss. Its own view with LOCAL drag state: on each
/// drag frame only this overlay is re-evaluated, not the whole library. That was
/// the cause of the stutter at drag start.
struct FullPlayerOverlay: View {
    @ObservedObject var coordinator: PlayerCoordinator
    let topInset: CGFloat
    let bottomInset: CGFloat
    /// Full screen height. Start/target value for the slide in/out.
    let presentHeight: CGFloat
    let onDismiss: () -> Void

    /// Live translation (resets instantly); handed over to releaseOffset at the end.
    @GestureState private var dragOffset: CGFloat = 0
    /// Carries slide-in, release handover, snap-back AND slide-out. A single,
    /// interruptible offset source instead of view transitions.
    @State private var releaseOffset: CGFloat
    /// Frame of the player's controls column (reported by PlayerView). The
    /// top and bottom zones are capped against it so they never cover the
    /// chapter buttons or the scrubber; the side strips stay clear by width.
    @State private var controlsFrame: CGRect?
    /// Rendered height of the notice pill, kept while no notice shows, so
    /// the next notice is placed at its real height at once.
    @State private var noticePillHeight: CGFloat = 0
    /// Whether the pill has room now; without it a stopping error stands as
    /// the line under the controls (`NoticePlacement`).
    @State private var pillHasRoom = true
    private let dismissThreshold: CGFloat = 180
    @Environment(\.sideColumnPlacement) private var columnPlacement

    init(
        coordinator: PlayerCoordinator,
        topInset: CGFloat,
        bottomInset: CGFloat,
        presentHeight: CGFloat,
        onDismiss: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.presentHeight = presentHeight
        self.onDismiss = onDismiss
        // Starts off-screen at the bottom, slides up in onAppear.
        _releaseOffset = State(initialValue: presentHeight)
    }

    var body: some View {
        let offset = max(0, dragOffset + releaseOffset)
        let progress = min(1, offset / dismissThreshold)
        // Base reveal > 0: at rest the sheet IS already the same glass sheet (no
        // mode switch at frame 1); the drag only intensifies it.
        let visual = SheetCorners.restReveal + (1 - SheetCorners.restReveal) * CGFloat(pow(Double(progress), 1.6))
        // Constant: glassEffect parameters must NOT change per frame, otherwise
        // the system re-renders the effect → stutter at drag start.
        let corner: CGFloat = 28
        ZStack(alignment: .top) {
            // Only dim the library (no blur); catches taps.
            Color.black
                // Factor fades the dim out on slide in/out (offset near screen
                // height → 0), otherwise a dim flash on mount/unmount.
                .opacity(Double(visual) * 0.45 * Double(1 - min(1, offset / presentHeight)))

            // The WHOLE glass sheet moves as one unit with the finger.
            ZStack(alignment: .top) {
                playerScreen(dragProgress: visual, cornerRadius: corner)
                    .environment(\.noticePillHasRoom, pillHasRoom)
                    .environment(\.closePlayer) { slideOutAndDismiss() }
                Group {
                    sideDismissZones
                    topDismissZone
                    bottomDismissZone
                }
                // The side column's strip stays free for its parts: the zones
                // lie over the player and would take their taps.
                .padding(columnPlacement?.edge ?? [], columnPlacement?.strip ?? 0)
                noticePill
                // Without the side column the handle closes the player; with
                // it the column's close button does (`PlayerView.sideColumn`).
                if columnPlacement == nil { grabHandle }
            }
            // Anchor for the controls-frame preference reported by PlayerView:
            // local frames stay stable while the whole sheet moves (offset).
            .coordinateSpace(name: CoordinateSpace.fullPlayerOverlayName)
            .onPreferenceChange(PlayerControlsFramePreferenceKey.self) { controlsFrame = $0 }
            .background { containerGlass(corner: corner) }
            .offset(y: offset)
            // VoiceOver: two-finger scrub (standard escape) closes the
            // player. The drag gesture is unusable with VoiceOver active.
            .accessibilityAction(.escape) { slideOutAndDismiss() }
        }
        // Ignore the safe area ONCE at the fixed root. Not in children of the
        // moving container, otherwise the expansion tips over by exactly the
        // inset height on the first offset frame (the "jump").
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) {
                releaseOffset = 0
            }
        }
        // A player with nothing in it closes: the finished title the mirror
        // cleared, the end of the queue. It hung over an empty spinner.
        .onChange(of: coordinator.screenContent == .nothing, initial: true) { _, isEmpty in
            if isEmpty { slideOutAndDismiss() }
        }
    }

    /// The player itself; with the tabs at the side it stands its own side
    /// column (`PlayerView`).
    private func playerScreen(dragProgress: CGFloat, cornerRadius: CGFloat) -> some View {
        PlayerScreen(
            coordinator: coordinator,
            dragProgress: dragProgress,
            cornerRadius: cornerRadius,
            topInset: topInset,
            bottomInset: bottomInset
        )
    }

    /// Static glass: tint/shape constant. The dynamic reveal runs exclusively via
    /// cheap opacity fades (background + dim).
    @ViewBuilder
    private func containerGlass(corner: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        if #available(iOS 26.0, *) {
            // Maximum, constant glass strength; reveal only via background fade.
            Color.clear
                .glassEffect(.regular.tint(Color.black.opacity(0.45)), in: shape)
        } else {
            // Fallback: material + matching tint.
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(Color.black.opacity(0.45)))
        }
    }

    /// The same pill of the one channel as above the mini bar, in the free
    /// space the controls leave (`PlayerDismissZones.noticeSlot`), never over
    /// a control. It stands above the dismiss zones, so a tap on it opens the
    /// log; it takes only its own capsule, the zones keep everything beside.
    private var noticePill: some View {
        GeometryReader { proxy in
            let slot = PlayerDismissZones.noticeSlot(
                controlsFrame: controlsFrame, container: proxy.size,
                topInset: topInset, bottomInset: bottomInset, pillHeight: noticePillHeight)
            ZStack(alignment: .topLeading) {
                if let slot {
                    ResumeMessageBanner(notices: coordinator.notices)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                            if height > 0 { noticePillHeight = height }
                        }
                        .frame(width: slot.width, height: slot.height, alignment: .bottom)
                        .offset(x: slot.minX, y: slot.minY)
                        // The full player is always dark. Keep the pill dark too.
                        .environment(\.colorScheme, .dark)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The same answer places the pill and tells the controls whether
            // a stopping error needs their line.
            .onChange(of: slot != nil, initial: true) { _, hasRoom in pillHasRoom = hasRoom }
        }
    }

    /// Centred above the cover, free of it; the tap area keeps the full width.
    private var grabHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.5))
            .frame(width: 40, height: 5)
            .padding(.top, topInset + 10)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            // A tap on the handle does what pulling it does: the pull takes
            // every touch first, so the tap is a pull that did not move
            // (`PlayerDismiss`). ONE closing function for the pull, the tap
            // and VoiceOver.
            .highPriorityGesture(dismissGesture(minimumDistance: 0, onHandle: true))
            .accessibilityLabel(Text("Close"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { slideOutAndDismiss() }
    }

    /// Slides the player out, then tears it down. The one way this player
    /// closes; no caller animates on its own.
    private func slideOutAndDismiss() {
        withAnimation(.easeOut(duration: 0.45)) {
            releaseOffset = presentHeight
        } completion: {
            onDismiss()
        }
    }

    /// A continuous full-height swipe strip along EACH screen edge, so
    /// drag-to-dismiss works from anywhere on the sides. Symmetric left/right.
    /// The strips are narrow (`sideStripWidth`) and the scrubber is inset past
    /// them (PlayerView), so they sit entirely in the outer margin, spatially
    /// clear of every control's hit target. No controls-frame height cap needed
    /// (the controls stay free by separation instead of capping). Verified via the harness
    /// (scrubber thumb at 0/1, outermost chapter buttons) on 375/402/440pt.
    private var sideDismissZones: some View {
        let w = PlayerDismissZones.sideStripWidth
        return HStack(spacing: 0) {
            edgeStrip(width: w)
            Spacer(minLength: 0)
            edgeStrip(width: w)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Full-height edge strip. contentShape is applied AFTER the height expands
    /// (unlike the top/bottom strips) because here the full height IS the
    /// intended hit area. The narrow fixed width keeps it off the controls.
    private func edgeStrip(width: CGFloat) -> some View {
        Color.clear
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(dismissGesture(minimumDistance: 12))
    }

    /// Full-width strip across the top (cover area). Pull-down can start
    /// anywhere up there, not just on the thin grab handle or the side rails.
    /// Capped against the controls frame: in iPhone landscape the side-by-side
    /// layout puts the scrubber INSIDE the former fixed-height strip.
    /// ORDER MATTERS: contentShape + gesture must attach to the SMALL strip
    /// BEFORE expanding the frame. Applied after `.frame(maxHeight:
    /// .infinity)` the hit shape covers the whole screen and the
    /// minimumDistance-0 drag swallows every tap (player appears dead).
    private var topDismissZone: some View {
        GeometryReader { _ in
            Color.clear
                .contentShape(Rectangle())
                .frame(height: PlayerDismissZones.topZoneHeight(
                    controlsFrame: controlsFrame, fallback: topInset + 130))
                .frame(maxWidth: .infinity)
                // Direction-arbitrating gesture (vertical → dismiss,
                // horizontal → chapter/track) so the cover-swipe works in portrait
                // where this strip covers the cover.
                .highPriorityGesture(coverAreaGesture())
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// Full-width strip across the free space BELOW the controls. No
    /// interactive elements there, so pull-down works from that area too. Same
    /// controls-frame mechanic as the top strip, anchored to the bottom edge.
    private var bottomDismissZone: some View {
        GeometryReader { proxy in
            let zone = PlayerDismissZones.bottomZone(
                controlsFrame: controlsFrame, containerHeight: proxy.size.height)
            Color.clear
                .frame(height: zone.height)
                .contentShape(Rectangle())
                .highPriorityGesture(dismissGesture(minimumDistance: 12))
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    /// Measured globally (offset container).
    private func dismissGesture(minimumDistance: CGFloat, onHandle: Bool = false) -> some Gesture {
        DragGesture(minimumDistance: minimumDistance, coordinateSpace: .global)
            .updating($dragOffset) { value, state, _ in
                state = max(0, value.translation.height)
            }
            .onEnded { value in handleDismissEnd(value, onHandle: onHandle) }
    }

    /// The top strip lies OVER the cover, so with `minimumDistance 0` its
    /// pull-down swallowed the horizontal cover-swipe before it could act.
    /// This variant arbitrates by direction: a vertical-dominant drag follows the
    /// sheet and can dismiss; a clearly horizontal fling navigates chapters
    /// (music: tracks) and leaves the sheet put. Used ONLY on the top/cover strip.
    /// The rails and the bottom strip keep the plain pull-down.
    private func coverAreaGesture() -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .updating($dragOffset) { value, state, _ in
                // Follow the sheet only while the drag is vertical-dominant.
                if abs(value.translation.height) >= abs(value.translation.width) {
                    state = max(0, value.translation.height)
                }
            }
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                if abs(dx) > abs(dy), abs(dx) > 50 {
                    coordinator.viewModel?.stepTitle(forward: dx < 0)
                    withAnimation(.snappy(duration: 0.32, extraBounce: 0.06)) { releaseOffset = 0 }
                    return
                }
                handleDismissEnd(value)
            }
    }

    private func handleDismissEnd(_ value: DragGesture.Value, onHandle: Bool = false) {
        let end = max(0, value.translation.height)
        let shouldDismiss = PlayerDismiss.closes(translation: value.translation,
                                                 predictedHeight: value.predictedEndTranslation.height,
                                                 threshold: dismissThreshold, onHandle: onHandle)
        // Take over the offset seamlessly (GestureState resets instantly).
        releaseOffset = end
        if shouldDismiss {
            // Slide out first, then tear down (no transition hitch).
            slideOutAndDismiss()
        } else {
            withAnimation(.snappy(duration: 0.32, extraBounce: 0.06)) {
                releaseOffset = 0
            }
        }
    }
}
