import SwiftUI


/// Full player with drag-to-dismiss. Its own view with LOCAL drag state: on each
/// drag frame only this overlay is re-evaluated, not the whole library — that was
/// the cause of the stutter at drag start.
struct FullPlayerOverlay: View {
    @ObservedObject var coordinator: PlayerCoordinator
    let topInset: CGFloat
    let bottomInset: CGFloat
    /// Full screen height — start/target value for the slide in/out.
    let presentHeight: CGFloat
    let onDismiss: () -> Void

    /// Live translation (resets instantly); handed over to releaseOffset at the end.
    @GestureState private var dragOffset: CGFloat = 0
    /// Carries slide-in, release handover, snap-back AND slide-out — a single,
    /// interruptible offset source instead of view transitions.
    @State private var releaseOffset: CGFloat
    private let dismissThreshold: CGFloat = 180

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
        let visual = CGFloat(0.15 + 0.85 * pow(Double(progress), 1.6))
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
                PlayerScreen(
                    coordinator: coordinator,
                    dragProgress: visual,
                    cornerRadius: corner,
                    topInset: topInset,
                    bottomInset: bottomInset
                )
                sideDismissZones
                topDismissZone
                grabHandle
            }
            .background { containerGlass(corner: corner) }
            .offset(y: offset)
            // VoiceOver: two-finger scrub (standard escape) closes the
            // player — the drag gesture is unusable with VoiceOver active.
            .accessibilityAction(.escape) {
                withAnimation(.easeOut(duration: 0.45)) {
                    releaseOffset = presentHeight
                } completion: {
                    onDismiss()
                }
            }
        }
        // Ignore the safe area ONCE at the fixed root — not in children of the
        // moving container, otherwise the expansion tips over by exactly the
        // inset height on the first offset frame (the "jump").
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) {
                releaseOffset = 0
            }
        }
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

    private var grabHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.5))
            .frame(width: 40, height: 5)
            .padding(.top, topInset + 10)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(dismissGesture)
            .accessibilityLabel(Text("Close player"))
            .accessibilityAddTraits(.isButton)
    }

    /// Side swipe zones; the bottom is left out (scrubber/controls). The width
    /// grows with the screen: everything outside the max 500pt wide content
    /// column (iPad/landscape), at least 56pt.
    private var sideDismissZones: some View {
        GeometryReader { proxy in
            let zoneWidth = max(56, (proxy.size.width - 520) / 2)
            HStack {
                dismissZone(width: zoneWidth)
                Spacer()
                dismissZone(width: zoneWidth)
            }
            .padding(.bottom, 220)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// Full-width strip across the top (cover area) — pull-down can start
    /// anywhere up there, not just on the thin grab handle or the side rails.
    /// ORDER MATTERS: contentShape + gesture must attach to the SMALL strip
    /// BEFORE expanding the frame — applied after `.frame(maxHeight:
    /// .infinity)` the hit shape covers the whole screen and the
    /// minimumDistance-0 drag swallows every tap (player appears dead).
    private var topDismissZone: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(height: topInset + 130)
            .frame(maxWidth: .infinity)
            .highPriorityGesture(dismissGesture)
            .frame(maxHeight: .infinity, alignment: .top)
    }

    private func dismissZone(width: CGFloat) -> some View {
        Color.clear
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(dismissGesture)
    }

    /// Measured globally (offset container), minimumDistance 0.
    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($dragOffset) { value, state, _ in
                state = max(0, value.translation.height)
            }
            .onEnded { value in
                let end = max(0, value.translation.height)
                let shouldDismiss = end > dismissThreshold
                    || value.predictedEndTranslation.height > dismissThreshold * 2
                // Take over the offset seamlessly (GestureState resets instantly).
                releaseOffset = end
                if shouldDismiss {
                    // Slide out first, then tear down (no transition hitch).
                    withAnimation(.easeOut(duration: 0.45)) {
                        releaseOffset = presentHeight
                    } completion: {
                        onDismiss()
                    }
                } else {
                    withAnimation(.snappy(duration: 0.32, extraBounce: 0.06)) {
                        releaseOffset = 0
                    }
                }
            }
    }
}
