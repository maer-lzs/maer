import SwiftUI


/// Voller Player mit Drag-to-dismiss. Eigene View mit LOKALEM Drag-State:
/// pro Ziehframe wird nur dieses Overlay neu ausgewertet, nicht die ganze
/// Bibliothek — das war die Ursache des Rucklers beim Ziehstart.
struct FullPlayerOverlay: View {
    @ObservedObject var coordinator: PlayerCoordinator
    let topInset: CGFloat
    let bottomInset: CGFloat
    /// Volle Bildschirmhöhe — Start-/Zielwert fürs Ein-/Ausfahren.
    let presentHeight: CGFloat
    let onDismiss: () -> Void

    /// Live-Translation (resettet instant); Übergabe an releaseOffset am Ende.
    @GestureState private var dragOffset: CGFloat = 0
    /// Trägt Einfahren, Loslass-Übergabe, Snap-back UND Ausfahren — eine
    /// einzige, unterbrechbare Offset-Quelle statt View-Transitions.
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
        // Startet unten außerhalb des Bildschirms, fährt in onAppear hoch.
        _releaseOffset = State(initialValue: presentHeight)
    }

    var body: some View {
        let offset = max(0, dragOffset + releaseOffset)
        let progress = min(1, offset / dismissThreshold)
        // Basis-Reveal > 0: das Sheet IST schon im Ruhezustand dasselbe
        // Glas-Sheet (kein Moduswechsel bei Frame 1); Zug verstärkt nur.
        let visual = CGFloat(0.15 + 0.85 * pow(Double(progress), 1.6))
        // Konstant: glassEffect-Parameter dürfen sich pro Frame NICHT ändern,
        // sonst rendert das System den Effekt neu → Ruckler beim Ziehstart.
        let corner: CGFloat = 28
        ZStack(alignment: .top) {
            // Bibliothek nur abdunkeln (kein Blur); fängt Taps ab.
            Color.black
                // Faktor blendet Dim beim Ein-/Ausfahren mit aus (Offset nahe
                // Bildschirmhöhe → 0), sonst Dim-Blitz beim Mount/Unmount.
                .opacity(Double(visual) * 0.45 * Double(1 - min(1, offset / presentHeight)))

            // Das GANZE Glas-Sheet bewegt sich als eine Einheit mit dem Finger.
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
        }
        // Safe Area EINMAL am fixen Root ignorieren — nicht in Kindern des
        // bewegten Containers, sonst kippt die Expansion beim ersten Offset-
        // Frame um genau die Inset-Höhe (der „Sprung“).
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) {
                releaseOffset = 0
            }
        }
    }

    /// Statisches Glas: Tönung/Form konstant. Der dynamische Reveal läuft
    /// ausschließlich über billige Opacity-Fades (Hintergrund + Dim).
    @ViewBuilder
    private func containerGlass(corner: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        if #available(iOS 26.0, *) {
            // Maximale, konstante Glas-Stärke; Reveal nur via Hintergrund-Fade.
            Color.clear
                .glassEffect(.clear.tint(Color.black.opacity(0.45)), in: shape)
        } else {
            // Fallback: Material + passende Tönung.
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
    }

    /// Seitliche Swipe-Zonen; unten ausgespart (Scrubber/Controls).
    /// Breite wächst mit dem Bildschirm: alles außerhalb der max. 500pt
    /// breiten Inhaltsspalte (iPad/Landscape), mindestens 56pt.
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
    private var topDismissZone: some View {
        Color.clear
            .frame(height: topInset + 130)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .highPriorityGesture(dismissGesture)
    }

    private func dismissZone(width: CGFloat) -> some View {
        Color.clear
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(dismissGesture)
    }

    /// Global gemessen (Offset-Container), minimumDistance 0.
    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($dragOffset) { value, state, _ in
                state = max(0, value.translation.height)
            }
            .onEnded { value in
                let end = max(0, value.translation.height)
                let shouldDismiss = end > dismissThreshold
                    || value.predictedEndTranslation.height > dismissThreshold * 2
                // Offset nahtlos übernehmen (GestureState resettet instant).
                releaseOffset = end
                if shouldDismiss {
                    // Selbst hinausfahren, dann erst abbauen (kein Transition-Hänger).
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
