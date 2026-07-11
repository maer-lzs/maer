import SwiftUI

struct PlayerView: View {
    @ObservedObject var viewModel: PlayerViewModel
    let coverURL: URL?
    /// Fortschritt der Nach-unten-Zieh-Geste (0…1) aus der Overlay-Präsentation.
    /// Blendet beim Ziehen den opaken Hintergrund aus, damit die Bibliothek
    /// dahinter durchscheint. 0 = Ruhezustand (immersiv, unverändert).
    var dragProgress: CGFloat = 0
    /// Eck-Radius des Overlay-Sheets (aus der Präsentation). Klippt den
    /// vollflächigen Hintergrund passend zur runden Glasform, damit keine
    /// eckigen Ecken über das Glas hinausragen. 0 = keine Rundung.
    var cornerRadius: CGFloat = 0
    /// Explizite Safe-Area-Insets (Overlay-Root ignoriert Safe Areas).
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0

    @StateObject private var colorLoader = CoverColorLoader()
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var showChapters = false
    @State private var showBookmarks = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private let availableRates: [Double] = [0.8, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]
    private let sleepOptions: [Double] = [5, 15, 30, 45, 60]

    var body: some View {
        GeometryReader { geo in
        ZStack {
            // Cover-Farbe als Hintergrund (Audible-Style) — als GEFÜLLTE runde
            // Form (nicht Gradient + clipShape). Grund: clipShape berechnete die
            // Rundung gegen die safe-area-große Fläche und ignoresSafeArea
            // streckte sie danach auf Vollbild — diese Streckung ist geometrie-
            // abhängig, sodass der obere Bereich beim ersten Ziehframe (Offset)
            // minimal „springen“ konnte. Als gefüllte Form wird die Rundung
            // direkt gegen die Vollbild-Geometrie gerechnet: identische Deckung
            // oben (Statusbar) bei Ruhe UND beim ersten Ziehframe, gleiche runde
            // Ecken wie der glassEffect.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [colorLoader.accent, Color.black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                // Ruhezustand ~0.9, beim Ziehen zügig ausblenden → Glass dominiert.
                .opacity(max(0.0, 0.9 - Double(dragProgress) * 0.9))

            // Querformat (iPhone UND iPad): Cover links neben den Controls.
            // Höhen-Guard: beim ersten Layout-Pass kann geo 0 melden — sonst
            // kippt der Zweig mitten in der Öffnungs-Animation (bleibt stecken).
            // AnyLayout statt if/else: stabile Identität bei Orientierungswechsel.
            let sideBySide = verticalSizeClass == .compact
                || (geo.size.height > 0 && geo.size.width > geo.size.height)
            let layout = sideBySide
                ? AnyLayout(HStackLayout(alignment: .center, spacing: 32))
                : AnyLayout(VStackLayout(spacing: 24))
            ScrollView {
                layout {
                    cover
                    VStack(spacing: 20) { controlsColumn }
                }
                .padding()
                .padding(.top, 8)
                // Lesbare Spalte hochkant, breiter nebeneinander.
                .frame(maxWidth: sideBySide ? 900 : 500)
                // Nebeneinander: vertikal im Viewport zentrieren (iPad).
                .frame(
                    maxWidth: .infinity,
                    minHeight: sideBySide ? max(0, geo.size.height - topInset - bottomInset) : 0
                )
            }
            // Kein Bounce, wenn der Inhalt passt → kein Scroll-Snap beim Ziehstart.
            .scrollBounceBehavior(.basedOnSize)
            // Insets explizit (Root ignoriert Safe Areas) → Layout wie zuvor.
            .padding(.top, topInset)
            .padding(.bottom, bottomInset)
        }
        .overlay(alignment: .bottom) {
            // Dieselbe globale Quell-/Sync-Hinweis-Pille wie über der
            // Mini-Leiste — im vollen Player unten mit kleinem Abstand über den
            // Steuerelementen. Nur sichtbar, wenn gesetzt (reserviert sonst
            // keinen Platz); rein informativ (allowsHitTesting(false) in der View).
            if viewModel.sourceHint != nil {
                ResumeMessageBanner(viewModel: viewModel)
                    .padding(.bottom, bottomInset + 16)
                    // The full player is always dark — keep the pill dark too.
                    .environment(\.colorScheme, .dark)
            }
        }
        .foregroundStyle(.white)
        .tint(.white)
        .task(id: coverURL) { await colorLoader.load(from: coverURL) }
        .sheet(isPresented: $showBookmarks) {
            BookmarksSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showChapters) {
            ChapterListView(
                chapters: viewModel.chapters,
                currentChapter: viewModel.currentChapter
            ) { chapter in
                viewModel.jumpToChapter(chapter)
                showChapters = false
            }
        }
        .alert(
            "Lower progress?",
            isPresented: Binding(
                get: { viewModel.pendingServerConflict != nil },
                set: { if !$0 { viewModel.dismissLowerProgressConflict() } }
            ),
            presenting: viewModel.pendingServerConflict
        ) { _ in
            Button("Overwrite", role: .destructive) {
                Task { await viewModel.confirmLowerProgress() }
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelAndRestoreServerPosition()
            }
        } message: { conflict in
            Text("Last saved: \(format(conflict.serverTime)). Current: \(format(conflict.localTime)). Nothing is overwritten without confirmation — Cancel jumps playback back to the saved position.")
        }
        .alert(
            "Multiple rapid skips detected",
            isPresented: Binding(
                get: { viewModel.suspiciousLockscreenJump != nil },
                set: { if !$0 { viewModel.dismissLockscreenJump() } }
            ),
            presenting: viewModel.suspiciousLockscreenJump
        ) { _ in
            Button("Yes, that was me") {
                Task { await viewModel.confirmLockscreenJump() }
            }
            Button("Back to \(format(viewModel.suspiciousLockscreenJump?.beforeTime ?? 0))", role: .cancel) {
                viewModel.cancelLockscreenJump()
            }
        } message: { jump in
            Text("Several rapid skips came in via the lock screen — this can easily happen from pocket contact. From \(format(jump.beforeTime)) to \(format(jump.afterTime)). Did you really skip that far?")
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background || newPhase == .inactive {
                Task { await viewModel.syncProgress(force: true) }
            } else if newPhase == .active {
                Task { await viewModel.reconcileWithServer() }
            }
        }
        } // GeometryReader
    }

    // MARK: - Bausteine

    /// Alle Bedienelemente unterhalb/neben dem Cover (geteilt Hoch/Quer).
    @ViewBuilder
    private var controlsColumn: some View {
        chapterHeader
        scrubber
        transportControls
        secondaryControls
        tertiaryControls
        if let error = viewModel.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private var cover: some View {
        CachedAsyncImage(url: coverURL) { image in
            image.resizable().aspectRatio(contentMode: .fit)
        } placeholder: {
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.1))
                .aspectRatio(1, contentMode: .fit)
                .overlay(Image(systemName: "book.closed").font(.largeTitle))
        }
        .frame(maxWidth: 300)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 12, y: 6)
        .overlay {
            if viewModel.isBuffering {
                ZStack {
                    Color.black.opacity(0.35)
                    VStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("Loading…").font(.caption)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var chapterHeader: some View {
        VStack(spacing: 4) {
            if let chapter = viewModel.currentChapter {
                Text(chapter.title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }
            if !viewModel.chapters.isEmpty {
                Text(chapterCounterText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            if let chapter = viewModel.currentChapter {
                // Chapter remaining + estimated finish time at current speed.
                Text("\(chapterRemainingMinutes(chapter)) min left in chapter · ends \(estimatedFinishTime())")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal)
    }

    private func chapterRemainingMinutes(_ chapter: ABSChapter) -> Int {
        max(1, Int((max(0, chapter.end - viewModel.currentTime) / 60).rounded(.up)))
    }

    /// Wall-clock time the BOOK finishes if playback continues at the
    /// current speed — the number night listeners actually care about.
    private func estimatedFinishTime() -> String {
        let rate = max(Double(viewModel.playbackRate), 0.1)
        let remaining = max(viewModel.duration - viewModel.currentTime, 0) / rate
        return Date().addingTimeInterval(remaining).formatted(date: .omitted, time: .shortened)
    }

    private var scrubber: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubValue : viewModel.currentTime },
                    set: { scrubValue = $0 }
                ),
                in: 0...(max(viewModel.duration, 1)),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if editing {
                        scrubValue = viewModel.currentTime
                    } else {
                        Task { await viewModel.seek(to: scrubValue) }
                    }
                }
            )
            .background(alignment: .leading) {
                // Kapitelmarken: kleine Striche an den Kapitelgrenzen. Rein
                // visuell, liegen hinter dem Slider-Track.
                if viewModel.duration > 0, viewModel.chapters.count > 1 {
                    GeometryReader { geo in
                        ForEach(viewModel.chapters) { chapter in
                            let x = geo.size.width * (chapter.start / viewModel.duration)
                            Rectangle()
                                .fill(.white.opacity(0.4))
                                .frame(width: 1.5, height: 10)
                                .position(x: x, y: geo.size.height / 2)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            HStack {
                Text(format(viewModel.currentTime))
                Spacer()
                Text("-" + format(max(viewModel.duration - viewModel.currentTime, 0)))
            }
            .monospacedDigit()
            .font(.caption)
            .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal)
    }

    private var transportControls: some View {
        let skip = Int(viewModel.skipInterval)
        return HStack(spacing: 24) {
            // Kapitel zurück (bzw. an den Kapitelanfang, siehe previousChapter).
            Button { viewModel.previousChapter() } label: {
                Image(systemName: "backward.end.fill").font(.title3)
            }
            .disabled(viewModel.chapters.isEmpty)
            .opacity(viewModel.chapters.isEmpty ? 0.3 : 1)
            .accessibilityLabel(Text("Previous chapter"))

            Button { viewModel.skip(by: -viewModel.skipInterval) } label: {
                Image(systemName: "gobackward.\(skip)").font(.title)
            }
            .accessibilityLabel(Text("Skip back \(skip) seconds"))
            Button { viewModel.togglePlayPause() } label: {
                Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 68))
            }
            .accessibilityLabel(viewModel.isPlaying ? Text("Pause") : Text("Play"))
            Button { viewModel.skip(by: viewModel.skipInterval) } label: {
                Image(systemName: "goforward.\(skip)").font(.title)
            }
            .accessibilityLabel(Text("Skip forward \(skip) seconds"))

            // Nächstes Kapitel.
            Button { viewModel.nextChapter() } label: {
                Image(systemName: "forward.end.fill").font(.title3)
            }
            .disabled(viewModel.chapters.isEmpty)
            .opacity(viewModel.chapters.isEmpty ? 0.3 : 1)
            .accessibilityLabel(Text("Next chapter"))
        }
    }

    private var secondaryControls: some View {
        HStack(spacing: 32) {
            Menu {
                // Picker inside a Menu shows a checkmark on the active rate.
                Picker("Speed", selection: Binding(
                    get: { Double(viewModel.playbackRate) },
                    set: { viewModel.setPlaybackRate(Float($0)) }
                )) {
                    ForEach(availableRates, id: \.self) { rate in
                        Text(rateLabel(rate) + "×").tag(rate)
                    }
                }
            } label: {
                Label(rateLabel(Double(viewModel.playbackRate)) + "×", systemImage: "speedometer")
                    // Non-default speed is visible at a glance.
                    .foregroundStyle(viewModel.playbackRate != 1.0 ? AnyShapeStyle(AppTheme.accent) : AnyShapeStyle(.white))
            }

            Button { showChapters = true } label: {
                Label("Chapters", systemImage: "list.bullet")
            }
            .disabled(viewModel.chapters.isEmpty)

            Menu {
                ForEach([15.0, 30.0, 60.0], id: \.self) { seconds in
                    Button("\(Int(seconds)) s") { viewModel.setSkipInterval(seconds) }
                }
            } label: {
                Label("\(Int(viewModel.skipInterval)) s", systemImage: "goforward")
            }

            Menu {
                ForEach(sleepOptions, id: \.self) { minutes in
                    Button("\(Int(minutes)) min") {
                        viewModel.startSleepTimer(minutes: minutes)
                    }
                }
                if !viewModel.chapters.isEmpty {
                    Button("Until End of Chapter") {
                        viewModel.startSleepTimerUntilChapterEnd()
                    }
                }
                if viewModel.canSleepUntilTrackEnd {
                    Button("Until End of Track") {
                        viewModel.startSleepTimerUntilTrackEnd()
                    }
                }
                if viewModel.sleepTimerRemaining != nil {
                    Divider()
                    Button("+15 min") {
                        viewModel.extendSleepTimer(byMinutes: 15)
                    }
                    Button("Stop Timer", role: .destructive) {
                        viewModel.cancelSleepTimer()
                    }
                }
            } label: {
                // Active timer: filled icon + accent color + live countdown —
                // the status is visible at a glance, not only inside the menu.
                Label(sleepTimerLabel, systemImage: viewModel.sleepTimerRemaining != nil ? "moon.zzz.fill" : "moon.zzz")
                    .foregroundStyle(viewModel.sleepTimerRemaining != nil ? AnyShapeStyle(AppTheme.accent) : AnyShapeStyle(.white))
            }
        }
        .font(.footnote)
        .padding(.top, 4)
    }

    private var tertiaryControls: some View {
        HStack(spacing: 36) {
            // AirPlay-Auswahl.
            AirPlayButton(tintColor: .white, activeTintColor: UIColor(AppTheme.accent))
                .frame(width: 44, height: 44)

            Button { showBookmarks = true } label: {
                Label("Bookmarks", systemImage: "bookmark")
            }
            .font(.footnote)

            Button {
                Task { await viewModel.toggleFinished() }
            } label: {
                Label(
                    viewModel.isFinished ? String(localized: "Mark Unfinished") : String(localized: "Mark Finished"),
                    systemImage: viewModel.isFinished ? "checkmark.circle.fill" : "checkmark.circle"
                )
            }
            .font(.footnote)
        }
        .padding(.top, 4)
    }

    // MARK: - Helfer

    private var chapterCounterText: String {
        guard let current = viewModel.currentChapter,
              let idx = viewModel.chapters.firstIndex(of: current) else { return "" }
        return String(localized: "Chapter \(idx + 1) of \(viewModel.chapters.count)")
    }

    private var sleepTimerLabel: String {
        guard let remaining = viewModel.sleepTimerRemaining else { return String(localized: "Sleep") }
        let minutes = Int(remaining) / 60
        let seconds = Int(remaining) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func rateLabel(_ rate: Double) -> String {
        var text = String(format: "%.2f", rate)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
