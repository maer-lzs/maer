import SwiftUI

struct PlayerView: View {
    @ObservedObject var viewModel: PlayerViewModel
    let coverURL: URL?
    /// Progress of the drag-down gesture (0…1) from the overlay presentation.
    /// Fades out the opaque background while dragging so the library shows
    /// through behind it. 0 = at rest (immersive, unchanged).
    var dragProgress: CGFloat = 0
    /// Corner radius of the overlay sheet (from the presentation). Clips the
    /// full-screen background to the rounded glass shape so no square corners
    /// stick out past the glass. 0 = no rounding.
    var cornerRadius: CGFloat = 0
    /// Explizite Safe-Area-Insets (Overlay-Root ignoriert Safe Areas).
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0

    @StateObject private var colorLoader = CoverColorLoader()
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var showChapters = false
    @State private var showBookmarks = false
    /// M4: lyrics of the CURRENT song (nil = none/still loading) + panel state.
    @State private var songLyrics: SongLyrics?
    @State private var showLyrics = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// D2/B2: at accessibility sizes the fixed-spacing control rows used to
    /// overflow the screen horizontally — spacing shrinks and the secondary/
    /// tertiary rows fall back to a two-column grid (ViewThatFits).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

    private let availableRates: [Double] = [0.8, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]
    private let sleepOptions: [Double] = [5, 15, 30, 45, 60]

    var body: some View {
        GeometryReader { geo in
        ZStack {
            // Cover color as background (Audible style) — as a FILLED rounded
            // shape (not gradient + clipShape). Reason: clipShape computed the
            // rounding against the safe-area-sized area and ignoresSafeArea then
            // stretched it to full screen — that stretch is geometry-dependent,
            // so the top could "jump" minimally on the first drag frame (offset).
            // As a filled shape the rounding is computed directly against the
            // full-screen geometry: identical top coverage (status bar) at rest
            // AND on the first drag frame, same rounded corners as the glassEffect.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [colorLoader.accent, Color.black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                // At rest ~0.9, fade out quickly while dragging → glass dominates.
                .opacity(max(0.0, 0.9 - Double(dragProgress) * 0.9))

            // Landscape (iPhone AND iPad): cover to the left of the controls.
            // Height guard: on the first layout pass geo can report 0 — otherwise
            // the branch tips over mid opening-animation (gets stuck). AnyLayout
            // instead of if/else: stable identity on orientation change.
            let sideBySide = verticalSizeClass == .compact
                || (geo.size.height > 0 && geo.size.width > geo.size.height)
            let layout = sideBySide
                ? AnyLayout(HStackLayout(alignment: .center, spacing: 32))
                : AnyLayout(VStackLayout(spacing: 24))
            ScrollView {
                layout {
                    cover
                    VStack(spacing: 20) { controlsColumn }
                        // Report the interactive controls' frame to the overlay:
                        // its dismiss zones are capped against it (D1) so the
                        // chapter buttons and the scrubber stay tappable.
                        .background(GeometryReader { controls in
                            Color.clear.preference(
                                key: PlayerControlsFramePreferenceKey.self,
                                value: controls.frame(in: .named(CoordinateSpace.fullPlayerOverlayName))
                            )
                        })
                }
                .padding()
                .padding(.top, 8)
                // Readable column in portrait, wider side by side.
                .frame(maxWidth: sideBySide ? 900 : 500)
                // Side by side: center vertically in the viewport (iPad).
                .frame(
                    maxWidth: .infinity,
                    minHeight: sideBySide ? max(0, geo.size.height - topInset - bottomInset) : 0
                )
            }
            // No bounce when the content fits → no scroll snap at drag start.
            .scrollBounceBehavior(.basedOnSize)
            // Explicit insets (root ignores safe areas) → layout as before.
            .padding(.top, topInset)
            .padding(.bottom, bottomInset)
        }
        .overlay(alignment: .bottom) {
            // The same global source/sync hint pill as above the mini bar — in
            // the full player at the bottom, slightly above the controls. Only
            // visible when set (reserves no space otherwise); purely
            // informational (allowsHitTesting(false) in the view).
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
        // M4: fetch lyrics per song change (cached; nil hides the button).
        .task(id: viewModel.currentMusicSong?.id) {
            guard let song = viewModel.currentMusicSong else { songLyrics = nil; return }
            songLyrics = await LyricsService.shared.lyrics(
                songId: song.id, artist: song.artist, title: song.title, duration: song.duration)
        }
        .sheet(isPresented: $showLyrics) {
            if let songLyrics, let song = viewModel.currentMusicSong {
                LyricsPanel(lyrics: songLyrics, songStart: song.start, viewModel: viewModel)
            }
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarksSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showChapters) {
            ChapterListView(
                chapters: viewModel.chapters,
                currentChapter: viewModel.currentChapter,
                isFallback: viewModel.chaptersAreFallback,
                isMusic: viewModel.isMusicItem
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

    // MARK: - Building blocks

    /// All controls below/beside the cover (shared portrait/landscape).
    @ViewBuilder
    private var controlsColumn: some View {
        chapterHeader
        if viewModel.isLiveStream {
            liveRow
        } else {
            scrubber
        }
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
        // S9: horizontal swipe on the cover = previous/next chapter. For music
        // each song is a chapter, so this is prev/next track. `simultaneous` so
        // it never blocks vertical scroll or the drag-to-dismiss; only a clearly
        // horizontal fling acts. No-op when the item has no chapters (guarded in
        // previous/nextChapter). Same behaviour as the chapter buttons.
        .simultaneousGesture(chapterSwipeGesture)
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

    /// S9: cover swipe → chapter/track navigation. Only a clearly horizontal
    /// fling (dominant x, past a threshold) acts, so vertical scroll and the
    /// drag-to-dismiss stay untouched. Left = next, right = previous.
    private var chapterSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy), abs(dx) > 50 else { return }
                if dx < 0 { viewModel.nextChapter() } else { viewModel.previousChapter() }
            }
    }

    private var chapterHeader: some View {
        VStack(spacing: 4) {
            // X14: the WORK is the large title (shared derivation — book/episode
            // title, the song title for music). It had silently vanished from the
            // player once T9d stopped baking the work title into the chapter
            // names ("Kapitel 71 – Armageddon …"); the player never had its own
            // title line, so only the cleaned chapter ("Teil 12") was left.
            Text(viewModel.nowPlayingTitle)
                .font(.title3).bold()
                .multilineTextAlignment(.center)
                .lineLimit(2)
            // Chapter / part line (T9c): a real chapter · author, the fallback
            // marker ("Teil 12 von 39" / "ab 3:15"), or the artist for music.
            if let subtitle = chapterSubtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
            // "N of M" only for REAL chapters — a fallback marker already carries
            // its position in the line above.
            if !viewModel.chaptersAreFallback, !viewModel.chapters.isEmpty {
                Text(chapterCounterText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            if let chapter = viewModel.currentChapter {
                // Chapter remaining + estimated finish time at current speed.
                // X18: music has no "chapters" — drop the "in chapter" phrasing.
                Text(viewModel.isMusicItem
                     ? "\(chapterRemainingMinutes(chapter)) min left · ends \(estimatedFinishTime())"
                     : "\(chapterRemainingMinutes(chapter)) min left in chapter · ends \(estimatedFinishTime())")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal)
    }

    /// X14: the line under the work title in the full player. For music the
    /// artist (the song is the title); for a fallback book the part/time marker
    /// (which the lock screen deliberately hides); otherwise "chapter · author".
    private var chapterSubtitle: String? {
        if viewModel.isMusicItem { return viewModel.nowPlayingSubtitle }
        if viewModel.chaptersAreFallback { return viewModel.currentChapter?.title }
        return viewModel.nowPlayingSubtitle
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

    /// F2: live radio — no scrubber, no duration; a LIVE mark plus the
    /// elapsed listening time (the only honest number for a stream).
    private var liveRow: some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 8, height: 8)
            Text(verbatim: "LIVE")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
            Spacer()
            Text(format(viewModel.currentTime))
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 24)
        .frame(minHeight: 44)
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
            // Recreate the slider when the item changes: Slider does not
            // reliably adopt a changed bounds range in place, which left the
            // thumb mapped against the previous episode's duration after an
            // auto-continue switch.
            .id(viewModel.item?.id)
            .background(alignment: .leading) {
                // Chapter marks: small ticks at the chapter boundaries. Purely
                // visual, sit behind the slider track.
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
            // D2: long durations ("-4:50:22") clipped at the right edge at
            // accessibility sizes — scale down instead of overflowing.
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(.white.opacity(0.8))
        }
        // S13: extra horizontal inset (16 → 24, on top of the content's 16) so
        // the slider track — and the thumb at position 0/1 — sits clear of the
        // 20pt full-height edge dismiss strips. The transport/chapter buttons are
        // centered and already well inside; only the full-width slider needed it.
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private var transportControls: some View {
        if viewModel.isLiveStream {
            // F2: live — play/pause is the whole transport.
            Button { viewModel.togglePlayPause() } label: {
                Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 68))
            }
            .accessibilityLabel(viewModel.isPlaying ? Text("Pause") : Text("Play"))
        } else {
            fullTransportControls
        }
    }

    private var fullTransportControls: some View {
        let skip = Int(viewModel.skipInterval)
        // D2: `.title`-scaled icons at AX sizes pushed the row past the screen
        // edge — tighter spacing and a capped type size keep all five controls
        // on screen (375pt worst case); the play glyph is fixed-size anyway.
        return HStack(spacing: isAccessibilitySize ? 12 : 24) {
            // Previous chapter (or to the chapter start, see previousChapter).
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

            // Next chapter.
            Button { viewModel.nextChapter() } label: {
                Image(systemName: "forward.end.fill").font(.title3)
            }
            .disabled(viewModel.chapters.isEmpty)
            .opacity(viewModel.chapters.isEmpty ? 0.3 : 1)
            .accessibilityLabel(Text("Next chapter"))
        }
        // Cap the icon growth at the first accessibility step — the buttons
        // stay large, but five of them still fit a 375pt screen.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    /// D2: one horizontal row while it fits; at accessibility sizes the four
    /// controls fall back to a leading-aligned two-column grid instead of
    /// clipping past the screen edge.
    @ViewBuilder
    private var secondaryControls: some View {
        if viewModel.isLiveStream {
            // F2: no speed, no chapters, no skip interval for live audio —
            // the sleep timer stays (clock-based options only; the chapter/
            // track-end options gate themselves out without chapters).
            HStack(spacing: 32) {
                sleepControl
            }
            .font(.footnote)
            .padding(.top, 4)
        } else {
            regularSecondaryControls
        }
    }

    private var regularSecondaryControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 32) {
                speedControl
                chaptersControl
                skipIntervalControl
                sleepControl
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow {
                    speedControl
                    chaptersControl
                }
                GridRow {
                    skipIntervalControl
                    sleepControl
                }
            }
        }
        .font(.footnote)
        .padding(.top, 4)
    }

    private var speedControl: some View {
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
    }

    private var chaptersControl: some View {
            Button { showChapters = true } label: {
                // X18/X23: shared selector label — tracks for music, parts for a
                // fallback book, chapters otherwise.
                Label(ChapterModel.selectorLabel(isMusic: viewModel.isMusicItem,
                                                 isFallback: viewModel.chaptersAreFallback),
                      systemImage: "list.bullet")
            }
            .disabled(viewModel.chapters.isEmpty)
    }

    private var skipIntervalControl: some View {
            Menu {
                ForEach([15.0, 30.0, 60.0], id: \.self) { seconds in
                    Button("\(Int(seconds)) s") { viewModel.setSkipInterval(seconds) }
                }
            } label: {
                Label("\(Int(viewModel.skipInterval)) s", systemImage: "goforward")
            }
    }

    private var sleepControl: some View {
            Menu {
                ForEach(sleepOptions, id: \.self) { minutes in
                    Button("\(Int(minutes)) min") {
                        viewModel.startSleepTimer(minutes: minutes)
                    }
                }
                // X18: music has no "chapter" boundary — "Until End of Track"
                // (below) is the song boundary, so skip the chapter option.
                if !viewModel.chapters.isEmpty && !viewModel.isMusicItem {
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

    /// D2: like secondaryControls — row while it fits, two-column grid at
    /// accessibility sizes (up to four items with the lyrics button).
    private var tertiaryControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 36) {
                tertiaryItems
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow {
                    airPlayControl
                    markFinishedControl
                }
                GridRow {
                    lyricsControl
                    bookmarksControl
                }
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var tertiaryItems: some View {
        airPlayControl
        lyricsControl
        bookmarksControl
        markFinishedControl
    }

    private var airPlayControl: some View {
        AirPlayButton(tintColor: .white, activeTintColor: AppTheme.accentUIColor)
            .frame(width: 44, height: 44)
    }

    /// M4: lyrics — music items only, and only when lyrics exist for the
    /// current song (server-first, LRCLIB fallback).
    @ViewBuilder
    private var lyricsControl: some View {
        if songLyrics != nil {
            Button { showLyrics = true } label: {
                Label("Lyrics", systemImage: "quote.bubble")
            }
            .font(.footnote)
        }
    }

    /// Only for sources with the bookmark capability (ABS can do it;
    /// future sources like RSS maybe not).
    @ViewBuilder
    private var bookmarksControl: some View {
        if viewModel.provider.capabilities.contains(.bookmarks) {
            Button { showBookmarks = true } label: {
                Label("Bookmarks", systemImage: "bookmark")
            }
            .font(.footnote)
        }
    }

    private var markFinishedControl: some View {
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

    // MARK: - Helfer

    private var chapterCounterText: String {
        guard let current = viewModel.currentChapter,
              let idx = viewModel.chapters.firstIndex(of: current) else { return "" }
        let count = viewModel.chapters.count
        // X18: music counts tracks, not chapters.
        return viewModel.isMusicItem
            ? String(localized: "Track \(idx + 1) of \(count)")
            : String(localized: "Chapter \(idx + 1) of \(count)")
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
