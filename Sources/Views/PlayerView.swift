import SwiftUI

struct PlayerView: View {
    @ObservedObject var viewModel: PlayerViewModel
    let coverURL: URL?

    @StateObject private var colorLoader = CoverColorLoader()
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var showChapters = false
    @Environment(\.scenePhase) private var scenePhase

    private let availableRates: [Double] = [0.8, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]
    private let sleepOptions: [Double] = [5, 15, 30, 45, 60]

    var body: some View {
        ZStack {
            // Cover-Farbe als Hintergrund-Gradient (Audible-Style).
            LinearGradient(
                colors: [colorLoader.accent, Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    cover
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
                .padding()
                .padding(.top, 8)
                // Auf dem iPad nicht über die volle Breite ziehen, sondern
                // eine lesbare Spalte zentrieren.
                .frame(maxWidth: 500)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(.white)
        .tint(.white)
        .task(id: coverURL) { await colorLoader.load(from: coverURL) }
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
            "Fortschritt senken?",
            isPresented: Binding(
                get: { viewModel.pendingServerConflict != nil },
                set: { if !$0 { viewModel.dismissLowerProgressConflict() } }
            ),
            presenting: viewModel.pendingServerConflict
        ) { _ in
            Button("Überschreiben", role: .destructive) {
                Task { await viewModel.confirmLowerProgress() }
            }
            Button("Abbrechen", role: .cancel) {
                viewModel.cancelAndRestoreServerPosition()
            }
        } message: { conflict in
            Text("Zuletzt gespeichert: \(format(conflict.serverTime)). Aktuell: \(format(conflict.localTime)). Ohne Bestätigung wird nichts überschrieben — bei Abbrechen springt die Wiedergabe zurück zum gespeicherten Stand.")
        }
        .alert(
            "Mehrere schnelle Sprünge erkannt",
            isPresented: Binding(
                get: { viewModel.suspiciousLockscreenJump != nil },
                set: { if !$0 { viewModel.dismissLockscreenJump() } }
            ),
            presenting: viewModel.suspiciousLockscreenJump
        ) { _ in
            Button("Ja, das war ich") {
                Task { await viewModel.confirmLockscreenJump() }
            }
            Button("Zurück zu \(format(viewModel.suspiciousLockscreenJump?.beforeTime ?? 0))", role: .cancel) {
                viewModel.cancelLockscreenJump()
            }
        } message: { jump in
            Text("Über den Sperrbildschirm kamen mehrere schnelle Sprünge hintereinander — das passiert leicht durch Tastenkontakt in der Tasche. Von \(format(jump.beforeTime)) auf \(format(jump.afterTime)). Wirklich so weit gesprungen?")
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background || newPhase == .inactive {
                Task { await viewModel.syncProgress(force: true) }
            } else if newPhase == .active {
                Task { await viewModel.reconcileWithServer() }
            }
        }
    }

    // MARK: - Bausteine

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
                        Text("Lädt…").font(.caption)
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
        }
        .padding(.horizontal)
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
            .font(.caption)
            .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal)
    }

    private var transportControls: some View {
        HStack(spacing: 28) {
            Button { viewModel.skip(by: -30) } label: {
                Image(systemName: "gobackward.30").font(.title)
            }
            Button { viewModel.togglePlayPause() } label: {
                Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 68))
            }
            Button { viewModel.skip(by: 30) } label: {
                Image(systemName: "goforward.30").font(.title)
            }
        }
    }

    private var secondaryControls: some View {
        HStack(spacing: 32) {
            Menu {
                ForEach(availableRates, id: \.self) { rate in
                    Button(rateLabel(rate) + "×") {
                        viewModel.setPlaybackRate(Float(rate))
                    }
                }
            } label: {
                Label(rateLabel(Double(viewModel.playbackRate)) + "×", systemImage: "speedometer")
            }

            Button { showChapters = true } label: {
                Label("Kapitel", systemImage: "list.bullet")
            }
            .disabled(viewModel.chapters.isEmpty)

            Menu {
                ForEach(sleepOptions, id: \.self) { minutes in
                    Button("\(Int(minutes)) Min") {
                        viewModel.startSleepTimer(minutes: minutes)
                    }
                }
                if !viewModel.chapters.isEmpty {
                    Button("Bis Kapitelende") {
                        viewModel.startSleepTimerUntilChapterEnd()
                    }
                }
                if viewModel.sleepTimerRemaining != nil {
                    Divider()
                    Button("Timer beenden", role: .destructive) {
                        viewModel.cancelSleepTimer()
                    }
                }
            } label: {
                Label(sleepTimerLabel, systemImage: "moon.zzz")
            }
        }
        .font(.footnote)
        .padding(.top, 4)
    }

    private var tertiaryControls: some View {
        HStack(spacing: 36) {
            // AirPlay-Auswahl.
            AirPlayButton(tintColor: .white)
                .frame(width: 44, height: 44)

            Button {
                Task { await viewModel.toggleFinished() }
            } label: {
                Label(
                    viewModel.isFinished ? "Als ungehört" : "Als gehört",
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
        return "Kapitel \(idx + 1) von \(viewModel.chapters.count)"
    }

    private var sleepTimerLabel: String {
        guard let remaining = viewModel.sleepTimerRemaining else { return "Sleep" }
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
