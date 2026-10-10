// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import Combine
import OSLog

struct PlayerView: View {
    @Environment(\.catalogFacts) private var catalogFacts
    @Environment(\.itemRouter) private var router
    @ObservedObject var viewModel: PlayerViewModel
    /// The coordinator, handed in by `PlayerScreen` and NOT observed: the
    /// page only acts on it (queue, radio, mark finished) and pulls the up
    /// next preview in its own task.
    let coordinator: PlayerCoordinator
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
    /// Up-Next home at the player: the global queue opens as a sheet from here.
    @State private var showQueue = false
    /// Lyrics of the CURRENT song (nil = none/still loading) + panel state.
    @State private var songLyrics: SongLyrics?
    @AppStorage(AppStorageKeys.musicLyricsOnlineLookup) private var lyricsOnline = true
    @State private var showLyrics = false
    /// Transcript of the CURRENT episode (nil = no tag/unparseable).
    @State private var transcript: SongLyrics?
    @State private var showTranscript = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// At accessibility sizes the fixed-spacing control rows used to
    /// overflow the screen horizontally. Spacing shrinks and the secondary/
    /// tertiary rows fall back to a two-column grid (ViewThatFits).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

    private let availableRates: [Double] = [0.8, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]
    private let sleepOptions: [Double] = [5, 15, 30, 45, 60]

    var body: some View {
        GeometryReader { geo in
        ZStack {
            // Cover color as background (Audible style). As a FILLED rounded
            // shape (not gradient + clipShape). Reason: clipShape computed the
            // rounding against the safe-area-sized area and ignoresSafeArea then
            // stretched it to full screen. That stretch is geometry-dependent,
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
            // Height guard: on the first layout pass geo can report 0. Otherwise
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
                        // its top and bottom zones are capped against it so the
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
            // The same global source/sync hint pill as above the mini bar. In
            // the full player at the bottom, slightly above the controls. Only
            // visible when set (reserves no space otherwise); purely
            // informational (allowsHitTesting(false) in the view).
            if viewModel.sourceHint != nil {
                ResumeMessageBanner(viewModel: viewModel)
                    .padding(.bottom, bottomInset + 16)
                    // The full player is always dark. Keep the pill dark too.
                    .environment(\.colorScheme, .dark)
            }
        }
        .foregroundStyle(.white)
        .tint(.white)
        .task(id: coverURL) { await colorLoader.load(from: coverURL) }
        // Fetch lyrics per song change (cached; nil hides the button).
        // The task id carries the opt-out. A flip re-evaluates
        // IMMEDIATELY (off drops cached web lyrics, no app restart).
        .task(id: "\(viewModel.currentMusicSong?.id ?? "-")-\(lyricsOnline)") {
            guard let song = viewModel.currentMusicSong else { songLyrics = nil; return }
            songLyrics = await LyricsService.shared.lyrics(
                songId: song.id, itemId: song.itemId, artist: song.artist, title: song.title,
                duration: song.duration)
        }
        .sheet(isPresented: $showLyrics) {
            Group {
                if let songLyrics, let song = viewModel.currentMusicSong {
                    LyricsPanel(lyrics: songLyrics, songStart: song.start, viewModel: viewModel)
                }
            }
            .followsAppearanceChoice()
        }
        // The transcript panel IS the lyrics panel (episode times are
        // absolute → songStart 0); entry exists only with a parsed transcript.
        .sheet(isPresented: $showTranscript) {
            Group {
                if let transcript {
                    LyricsPanel(lyrics: transcript, title: "Transcript",
                                songStart: 0, viewModel: viewModel)
                }
            }
            .followsAppearanceChoice()
        }
        .task(id: viewModel.item?.id) {
            // The full player says which title it holds, on notice so a
            // device archive carries it: a control that does nothing on
            // one title and works on every other is a question about the
            // title's identity, and that is answered here, not guessed.
            Logger.library.notice("PLAYER open item=\(viewModel.item?.id ?? "nil", privacy: .public) tools=\(tools.count)")
            transcript = nil
            guard let id = viewModel.item?.id, PlayerSourceTargets.isPodcast(id),
                  let url = PodcastSubscriptions.shared.episode(guid: id)?.episode.transcriptURL,
                  !url.isEmpty else { return }
            transcript = await PodcastTranscriptService.shared.transcript(for: url)
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarksSheet(viewModel: viewModel)
                .followsAppearanceChoice()
        }
        .sheet(isPresented: $showQueue) {
            // The coordinator the page was handed, the same instance the
            // library observes.
            PlayQueueSheet(playerCoordinator: coordinator)
                .followsAppearanceChoice()
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
            .followsAppearanceChoice()
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
            Text("Last saved: \(format(conflict.serverTime)). Current: \(format(conflict.localTime)). Nothing is overwritten without confirmation. Cancel jumps playback back to the saved position.")
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
            Text("Several rapid skips came in via the lock screen. This can easily happen from pocket contact. From \(format(jump.beforeTime)) to \(format(jump.afterTime)). Did you really skip that far?")
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background || newPhase == .inactive {
                Task { await viewModel.syncProgress(.background) }
            } else if newPhase == .active {
                Task { await viewModel.reconcileWithServer() }
            }
        }
        } // GeometryReader
    }

    /// The cached answer of the what-plays-next line. CACHED on purpose:
    /// `currentTime` is @Published, so this body re-evaluates every second
    /// while playing, and computing the cascade there would put a
    /// subscription scan on the main actor at 1 Hz on the surface the
    /// hitch probes measure. The truth changes only when the lists, the
    /// progress store or the title change, and exactly those recompute it.
    @State private var upNextItem: LibraryItem?

    /// The TRUTH of the cascade, readable without a tap: what actually
    /// plays when this title ends. Same computation as the jump itself
    /// (`resolveAdvance`); if nothing would play, the line shows nothing,
    /// never an invented continuation.
    @ViewBuilder
    private var upNextLine: some View {
        Group {
            if let next = upNextItem {
                Text("Up Next: \(next.title)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .padding(.horizontal)
                    .accessibilityIdentifier("player-up-next-line")
            }
        }
        .task(id: viewModel.item?.id) { recomputeUpNext() }
        .onReceive(PlayQueue.shared.objectWillChange) { _ in recomputeUpNext() }
        .onReceive(PlaybackContext.shared.objectWillChange) { _ in recomputeUpNext() }
        // The binge answer turns with progress (an episode marked played
        // moves the next-unheard pointer); the tick computation used to
        // cover that by accident, the cached form names its trigger.
        .onReceive(PodcastProgressStore.shared.objectWillChange) { _ in recomputeUpNext() }
    }

    private func recomputeUpNext() {
        upNextItem = coordinator.upNextPreview()
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
        upNextLine
        if let error = viewModel.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var cover: some View {
        Group {
            if viewModel.isLiveStream {
                if let songCover = viewModel.icySongArtwork {
                    // Teil 2: a resolved now-playing cover (MusicBrainz → Cover
                    // Art Archive) is real album art. Show it full size.
                    Image(uiImage: songCover)
                        .resizable().aspectRatio(1, contentMode: .fit)
                        .transition(.opacity)
                } else {
                    // Radio. Never upscale a low-res favicon fullscreen. A
                    // station-color field carries a small, sharp logo (or the SF
                    // symbol). Shared with the station rows via `RadioArtwork`.
                    RadioArtwork(stationID: viewModel.item?.id ?? "",
                                 faviconURL: coverURL,
                                 name: viewModel.item?.media.metadata?.title ?? "",
                                 isHero: true)
                        .aspectRatio(1, contentMode: .fit)
                }
            } else {
                CachedAsyncImage(url: coverURL) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.white.opacity(0.1))
                        .aspectRatio(1, contentMode: .fit)
                        // The item's own symbol; it said "book" for music too.
                        .overlay(Image(systemName: MediaFamily.placeholderSymbol(
                            for: viewModel.item?.id ?? "",
                            markedForm: viewModel.item.flatMap { ListeningStore.startedForm($0.id) }))
                            .font(.largeTitle))
                }
            }
        }
        .frame(maxWidth: 300)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 12, y: 6)
        // Horizontal swipe on the cover = previous/next chapter. For music
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

    /// Cover swipe → chapter/track navigation. Only a clearly horizontal
    /// fling (dominant x, past a threshold) acts, so vertical scroll and the
    /// drag-to-dismiss stay untouched. Left = next, right = previous.
    private var chapterSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy), abs(dx) > 50 else { return }
                viewModel.stepTitle(forward: dx < 0)
            }
    }

    private var chapterHeader: some View {
        VStack(spacing: 4) {
            if viewModel.isLiveStream {
                // Radio shows the STATION as the big title, with the
                // current ICY song underneath (in-app arrangement; the lock
                // screen stays song-first per Apple's convention).
                // This live branch used to render the station as PLAIN text
                // while the tappable title only lived in the else branch
                // radio never reaches. Same wrapper now. Plain again when
                // the station cannot be resolved.
                sourceTappable(target: titleTarget, a11yId: "player-source-title") {
                    // Pipe-junk trimmed for display everywhere.
                    Text(RadioMapping.displayName(viewModel.stationName))
                        .font(.title3).bold()
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                if let nowPlaying = viewModel.icyDisplayLine {
                    Text(nowPlaying)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            } else {
            // The WORK is the large title (shared derivation. Book/episode
            // title, the song title for music). The chapter names do not carry
            // the work title, so without this line only the cleaned chapter
            // ("Teil 12") would be left.
            // Title/subtitle navigate to the source page (Apple-
            // Media convention). Book title → book detail, podcast subtitle
            // → show page, music subtitle → album page. Plain text when no
            // target resolves (radio, unresolvable ids).
            sourceTappable(target: titleTarget, a11yId: "player-source-title") {
                Text(viewModel.nowPlayingTitle)
                    .font(.title3).bold()
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            // Chapter / part line: a real chapter · author, the fallback
            // marker ("Teil 12 von 39" / "ab 3:15"), or the artist for music.
            if let subtitle = chapterSubtitle {
                sourceTappable(target: subtitleTarget, a11yId: "player-source-subtitle") {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
            }
            // "N of M" only for REAL chapters. A fallback marker already carries
            // its position in the line above.
            if !viewModel.chaptersAreFallback, !viewModel.chapters.isEmpty {
                Text(chapterCounterText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            if let chapter = viewModel.currentChapter {
                // Chapter remaining + estimated finish time at current speed.
                // Music has no "chapters". Drop the "in chapter" phrasing.
                let left = DurationText.remaining(minutes: chapterRemainingMinutes(chapter))
                Text(viewModel.isMusicItem
                     ? "\(left) · ends \(estimatedFinishTime())"
                     : "\(left) in chapter · ends \(estimatedFinishTime())")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .monospacedDigit()
            }
            }
        }
        .padding(.horizontal)
    }

    /// The line under the work title in the full player. For music the
    /// artist (the song is the title); for a fallback book the part/time marker
    /// (which the lock screen deliberately hides); otherwise "chapter · author".
    // MARK: - Source navigation

    /// Gate 2: taps go through the ONE central router (environment wiring
    /// was fragile across presentation contexts. Silent no-op on device).
    /// Log-first: the tap log fires BEFORE routing, so a dead device tap is
    /// distinguishable (tap logged + no route = handler lost; nothing logged
    /// = the tap never reaches the button).
    private func openPlayerSource(_ target: PlayerSourceTarget) {
        Logger.player.notice("PLAYERSOURCE tap target=\(String(describing: target), privacy: .public)")
        PlayerSourceRouter.shared.open(target)
    }

    /// Wraps a line in a Button when a source target exists; ONE context menu
    /// on the tappable line carries the further destinations (music: artist ·
    /// podcast: episode) plus the queue entry. No parallel mechanics.
    @ViewBuilder
    private func sourceTappable(target: PlayerSourceTarget?, a11yId: String,
                                @ViewBuilder content: () -> some View) -> some View {
        // Only offer the tap affordance when a route can actually be
        // taken. No target OR no registered router handler renders PLAIN.
        // A subtle chevron marks the navigable line; it exists ONLY together
        // with the resolvable target, in the same branch as the tap.
        if let target, PlayerSourceRouter.shared.canRoute {
            Button {
                openPlayerSource(target)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    content()
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
                .buttonStyle(.plain)
                .accessibilityIdentifier(a11yId)
                .contextMenu { sourceMenu }
        } else {
            content()
        }
    }

    /// The primary tap target of the TITLE line: the book detail
    /// (audiobooks). Or the STATION detail for a live radio stream
    /// (the title IS the station there).
    private var titleTarget: PlayerSourceTarget? {
        guard let id = viewModel.item?.id else { return nil }
        if viewModel.isLiveStream {
            guard PlayerSourceTargets.isRadio(id),
                  let station = RadioProvider.shared.station(forId: id) else { return nil }
            return .radioStation(station)
        }
        guard PlayerSourceTargets.isBook(id) else { return nil }
        return .book(itemId: id)
    }

    /// The primary tap target of the SUBTITLE line: show page (podcast) or
    /// album page (music).
    private var subtitleTarget: PlayerSourceTarget? {
        guard let id = viewModel.item?.id, !viewModel.isLiveStream else { return nil }
        if PlayerSourceTargets.isPodcast(id) {
            guard let feed = PodcastSubscriptions.shared.feedURL(forEpisodeId: id) else { return nil }
            return .podcastShow(feedURL: feed)
        }
        if PlayerSourceTargets.isMusic(id) {
            if let item = router.item(id) { return .musicAlbum(item) }
            if let detail = viewModel.item {
                return .musicAlbum(LibraryItem(id: detail.id, media: detail.media, addedAt: nil))
            }
        }
        // A catalogue item has its own page; without this it fell into the
        // book branch and opened an empty audiobook detail.
        if PlayerSourceTargets.isCatalog(id) { return .catalogAlbum(itemId: id) }
        // No target means no menu entry. And the reason is logged rather
        // than swallowed, so an unknown namespace surfaces instead of hiding.
        if MediaFamily.of(id) == .unknown {
            Logger.library.error("PLAYERSOURCE no target for unknown id family: \(id, privacy: .public)")
        }
        return nil
    }

    @ViewBuilder
    private var sourceMenu: some View {
        if let id = viewModel.item?.id {
            if let subtitleTarget {
                Button {
                    openPlayerSource(subtitleTarget)
                } label: {
                    PlayerSourceTargets.isPodcast(id)
                        ? Label("Go to Show", systemImage: "mic")
                        : Label("Go to Album", systemImage: "square.stack")
                }
            }
            if PlayerSourceTargets.isPodcast(id) {
                Button {
                    openPlayerSource(.podcastEpisode(itemId: id))
                } label: { Label("Go to Episode", systemImage: "doc.text") }
            }
            if PlayerSourceTargets.isMusic(id), let artistName = viewModel.item?.media.metadata?.authorName {
                Button {
                    Task {
                        // Best-effort name match. The playing detail carries no
                        // artist id; unresolvable stays a silent no-op.
                        let artists = (try? await AppSession.shared.musicProvider(for: id).allArtists()) ?? []
                        if let artist = artists.first(where: { $0.name == artistName }) {
                            openPlayerSource(.musicArtist(artist))
                        }
                    }
                } label: { Label("Go to Artist", systemImage: "music.mic") }
            }
            Button {
                showQueue = true
            } label: { Label("Up Next", systemImage: "list.triangle") }
        }
    }

    private var chapterSubtitle: String? {
        if viewModel.isMusicItem { return viewModel.nowPlayingSubtitle }
        if viewModel.chaptersAreFallback { return viewModel.currentChapter?.title }
        return viewModel.nowPlayingSubtitle
    }

    private func chapterRemainingMinutes(_ chapter: ABSChapter) -> Int {
        max(1, Int((max(0, chapter.end - viewModel.currentTime) / 60).rounded(.up)))
    }

    /// Wall-clock time the BOOK finishes if playback continues at the
    /// current speed. The number night listeners actually care about.
    private func estimatedFinishTime() -> String {
        let rate = max(Double(viewModel.playbackRate), 0.1)
        let remaining = max(viewModel.duration - viewModel.currentTime, 0) / rate
        return Date().addingTimeInterval(remaining).formatted(date: .omitted, time: .shortened)
    }

    /// Teil 1: the active radio station (with its variants). Resolved from the
    /// store/session so the live quality menu can offer the codec/bitrate
    /// variants. nil for non-radio or a single-variant station (→ no menu).
    private var liveStation: RadioStation? {
        guard viewModel.isLiveStream, let id = viewModel.item?.id,
              let station = RadioProvider.shared.station(forId: id),
              station.variantList.count > 1 else { return nil }
        return station
    }

    /// Live radio. No scrubber, no duration; a LIVE mark plus the
    /// elapsed listening time (the only honest number for a stream). Teil 1: a
    /// quality menu appears when the station ships codec/bitrate variants.
    private var liveRow: some View {
        HStack(spacing: 8) {
            LiveBadge()
            Spacer()
            if let station = liveStation { qualityMenu(for: station) }
            Text(format(viewModel.currentTime))
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
        }
        // The row stands where the scrubber stands, with the quality menu at
        // its edge: the same inset keeps it clear of the side strips.
        .padding(.horizontal, PlayerDismissZones.scrubberInset)
        .frame(minHeight: 44)
    }

    /// Teil 1: switch the live stream to another codec/bitrate variant. Good
    /// when the current one stutters. The choice persists per station and the
    /// station re-opens at the chosen stream (the play path picks it up).
    private func qualityMenu(for station: RadioStation) -> some View {
        let selected = RadioStore.selectedVariantURL(for: station) ?? station.streamURL
        return Menu {
            // Keyed by address, like the folding and the choice: two
            // answers can give one id two addresses.
            ForEach(station.variantList, id: \.streamURL) { variant in
                Button {
                    RadioStore.setSelectedVariant(variant.streamURL, for: station)
                    RadioPlay.play(station, playerCoordinator: coordinator)
                } label: {
                    if variant.streamURL == selected {
                        Label(variant.qualityLabel, systemImage: "checkmark")
                    } else {
                        Text(variant.qualityLabel)
                    }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
        }
        .accessibilityLabel(Text("Stream Quality"))
    }

    /// What the bar spans: the work for spoken word, the SONG for music
    /// (the convention of every music player). One question, asked here.
    private var scrubberSpan: ScrubberSpan {
        ScrubberSpan.of(isMusic: viewModel.isMusicItem,
                        chapterStart: viewModel.currentChapter?.start,
                        chapterEnd: viewModel.currentChapter?.end,
                        duration: viewModel.duration)
    }

    private var scrubber: some View {
        VStack(spacing: 8) {
            // The ONE slider of the app, and on the Mac the system one
            // crashes inside Apple's fluid-slider haptics (six reports,
            // two app versions, no app frame). PlatformScrubber keeps
            // the system Slider everywhere except there.
            PlatformScrubber(
                value: Binding(
                    get: { isScrubbing ? scrubValue : scrubberSpan.position(absolute: viewModel.currentTime) },
                    set: { scrubValue = $0 }
                ),
                range: 0...scrubberSpan.length,
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if editing {
                        scrubValue = scrubberSpan.position(absolute: viewModel.currentTime)
                    } else {
                        let target = scrubberSpan.absolute(position: scrubValue)
                        Task { await viewModel.seek(to: target) }
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
                // Only where the bar spans the whole work: with music the
                // bar IS one song, so a mark at every other song would sit
                // outside what it spans.
                if viewModel.duration > 0, viewModel.chapters.count > 1, !viewModel.isMusicItem {
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
                Text(format(scrubberSpan.elapsed(absolute: viewModel.currentTime)))
                Spacer()
                Text("-" + format(scrubberSpan.remaining(absolute: viewModel.currentTime)))
            }
            .monospacedDigit()
            .font(.caption)
            // Long durations ("-4:50:22") clipped at the right edge at
            // accessibility sizes. Scale down instead of overflowing.
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(.white.opacity(0.8))
        }
        // Extra horizontal inset (16 → 24, on top of the content's 16) so
        // the slider track, and the thumb at position 0/1, sits clear of the
        // 20pt full-height edge dismiss strips. The transport/chapter buttons are
        // centered and already well inside; only the full-width slider needed it.
        .padding(.horizontal, PlayerDismissZones.scrubberInset)
    }

    @ViewBuilder
    private var transportControls: some View {
        if viewModel.isLiveStream {
            // Live. Play/pause is the whole transport.
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
        // `.title`-scaled icons at AX sizes pushed the row past the screen
        // edge. Tighter spacing and a capped type size keep all five controls
        // on screen (375pt worst case); the play glyph is fixed-size anyway.
        return HStack(spacing: isAccessibilitySize ? 12 : 24) {
            // Previous chapter, or for songs the title way (see stepTitle).
            Button { viewModel.stepTitle(forward: false) } label: {
                Image(systemName: "backward.end.fill").font(.title3)
            }
            .disabled(viewModel.chapters.isEmpty)
            .opacity(viewModel.chapters.isEmpty ? 0.3 : 1)
            .accessibilityLabel(Text(RemoteCommandRule.keyLabels(for: viewModel.titleStep).back))

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

            // Next chapter, or for songs the title way (see stepTitle).
            Button { viewModel.stepTitle(forward: true) } label: {
                Image(systemName: "forward.end.fill").font(.title3)
            }
            .disabled(viewModel.chapters.isEmpty)
            .opacity(viewModel.chapters.isEmpty ? 0.3 : 1)
            .accessibilityLabel(Text(RemoteCommandRule.keyLabels(for: viewModel.titleStep).forward))
        }
        // Cap the icon growth at the first accessibility step. The buttons
        // stay large, but five of them still fit a 375pt screen.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    /// One horizontal row while it fits; at accessibility sizes the four
    /// controls fall back to a leading-aligned two-column grid instead of
    /// clipping past the screen edge.
    @ViewBuilder
    private var secondaryControls: some View {
        if viewModel.isLiveStream {
            // No speed, no chapters, no skip interval for live audio.
            // The sleep timer stays (clock-based options only; the chapter/
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

    /// Row 2 shows only what exists. No chapters/parts ⇒ NO chapters button
    /// (a disabled ghost was a broken promise); the row closes up. Speed/
    /// skip/sleep are universal and stay.
    private var hasChapterEntry: Bool { !viewModel.chapters.isEmpty }

    private var regularSecondaryControls: some View {
        // MeasuredFits, not ViewThatFits. These controls
        // carry live viewModel bindings, and ViewThatFits would evaluate
        // their bodies on the AsyncRenderer (the tab-bar crash, same bomb).
        MeasuredFits {
            HStack(spacing: 32) {
                speedControl
                if hasChapterEntry { chaptersControl }
                skipIntervalControl
                sleepControl
            }
        } compact: {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow {
                    speedControl
                    if hasChapterEntry { chaptersControl }
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
                // Shared selector label. Tracks for music, parts for a
                // fallback book, chapters otherwise.
                Label(ChapterModel.selectorLabel(isMusic: viewModel.isMusicItem,
                                                 isFallback: viewModel.chaptersAreFallback),
                      systemImage: "list.bullet")
            }
    }

    private var skipIntervalControl: some View {
            Menu {
                ForEach(PlaybackSkip.options(for: viewModel.skipContent), id: \.self) { seconds in
                    Button("\(Int(seconds)) s") { viewModel.setSkipInterval(seconds) }
                }
            } label: {
                Label("\(Int(viewModel.skipInterval)) s", systemImage: "goforward")
            }
    }

    private var sleepControl: some View {
            Menu {
                // The duration of the last time, at the top and in one tap.
                // Only shown while no timer runs, and only when it is not
                // already the first row anyway.
                if viewModel.sleepTimerRemaining == nil,
                   let last = AppStorageKeys.sleepTimerRemembered,
                   last != sleepOptions.first {
                    Button("Again: \(DurationText.length(minutes: Int(last)))") {
                        viewModel.startSleepTimer(minutes: last)
                    }
                    Divider()
                }
                ForEach(sleepOptions, id: \.self) { minutes in
                    Button(DurationText.length(minutes: Int(minutes))) {
                        viewModel.startSleepTimer(minutes: minutes)
                    }
                }
                // Music has no "chapter" boundary. "Until End of Track"
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
                // Active timer: filled icon + accent color + live countdown.
                // The status is visible at a glance, not only inside the menu.
                Label(sleepTimerLabel, systemImage: viewModel.sleepTimerRemaining != nil ? "moon.zzz.fill" : "moon.zzz")
                    .foregroundStyle(viewModel.sleepTimerRemaining != nil ? AnyShapeStyle(AppTheme.accent) : AnyShapeStyle(.white))
            }
    }

    /// Variant A for ALL media types.
    /// An extras row (Up Next · bookmarks · lyrics for music · transcript
    /// for podcasts · a more menu with drive mode and mark as heard) with
    /// AirPlay SOLO centred below it. Radio runs through the same structure
    /// with fewer entries. At accessibility sizes the extras row falls into a
    /// two-column grid.
    /// Drive mode + mark-finished moved OUT of the "…" menu into
    /// the row. The menu emptied and is GONE. Overflow (the German-labels
    /// worst case with a full six-item row): ViewThatFits tries the labeled
    /// row first; when it cannot fit, the SAME buttons render icon-only
    /// (a11y labels intact). Never the jagged two-column grid again. With
    /// gated entries missing (no lyrics/transcript), labels usually fit.
    private var tertiaryControls: some View {
        VStack(spacing: 18) {
            // MeasuredFits, not ViewThatFits. Same bomb as
            // the secondary row, same cure.
            MeasuredFits {
                HStack(spacing: 36) {
                    extrasItems
                }
            } compact: {
                HStack(spacing: 28) {
                    extrasItems
                }
                .labelStyle(.iconOnly)
                .font(.body)
            }
            airPlayControl
        }
        .padding(.top, 4)
    }

    /// ONE decision for the whole row: every tool appears because the
    /// running title's kind or source knows it (`PlayerToolRule`), and
    /// no button decides for itself.
    private var tools: Set<PlayerToolRule.Tool> {
        let id = viewModel.item?.id ?? ""
        let content: PlayerToolRule.Content
        if viewModel.isLiveStream {
            content = .liveStream
        } else if MediaFamily.isMusicByForm(id) {
            content = .music
        } else {
            content = .spokenWord
        }
        return PlayerToolRule.tools(for: .init(
            content: content,
            providerKeepsBookmarks: viewModel.provider.capabilities.contains(.bookmarks),
            hasLyrics: songLyrics != nil,
            hasTranscript: transcript != nil,
            isCatalogue: ItemNamespace.isCatalog(id)))
    }

    @ViewBuilder
    private var extrasItems: some View {
        let tools = tools
        if tools.contains(.queue) { queueControl }
        if tools.contains(.bookmarks) { bookmarksControl }
        if tools.contains(.lyrics) { lyricsControl }
        if tools.contains(.transcript) { transcriptControl }
        if tools.contains(.driveMode) { driveModeControl }
        if tools.contains(.markFinished) { markFinishedControl }
        if tools.contains(.playlist) { playlistControl }
        if tools.contains(.source) { catalogSourceControl }
    }

    /// The player is the surface with the strongest reason to put a running
    /// title into a playlist and had the weakest equipment for it: neither a
    /// queue nor a playlist action. Both come from the SAME shared component
    /// as everywhere else.
    @ViewBuilder
    private var playlistControl: some View {
        if let id = viewModel.item?.id {
            Menu {
                CatalogQueueButtons(itemId: id)
            } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
                    .font(.footnote)
            }
            .accessibilityIdentifier("player-add-to-playlist")
        }
    }

    private var driveModeControl: some View {
        Button { DriveModeController.shared.enter() } label: {
            Label("Drive Mode", systemImage: "car.fill")
        }
        .font(.footnote)
        .accessibilityIdentifier("player-drive-mode")
    }

    /// Since the music catalog tiles PLAY on tap, the path skips the detail
    /// sheet, and that is where the ToS-mandated attribution stood (artist,
    /// provider, backlink). The player carries it itself now: licence and
    /// source visible, with a link to the source page. No catalog title means
    /// no line.
    @ViewBuilder
    private var catalogSourceControl: some View {
        if let id = viewModel.item?.id, ItemNamespace.isCatalog(id) {
            let licence = catalogFacts.licence(id)
            let source = catalogFacts.sourceURL(id)
            VStack(alignment: .leading, spacing: 4) {
                if id.hasPrefix(FreeCatalog.jamendoPrefix) {
                    Label("Creative Commons, via Jamendo", systemImage: "checkmark.seal")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if let licence {
                    Label(licence, systemImage: "checkmark.seal")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let source {
                    Link(destination: source) {
                        Label("View source", systemImage: "arrow.up.right.square")
                            .font(.footnote)
                    }
                    .accessibilityIdentifier("player-zur-quellseite")
                }
            }
        }
    }

    private var markFinishedControl: some View {
        // In the player the marked item is by definition the running one,
        // so marking it as heard stops it. `toggleFinished` alone only flips
        // the mark. Read the direction FIRST, because afterwards it has
        // already turned; the opposite direction stays without effect and
        // leaves position and playback untouched.
        // The player's flag is the true end already (the tail never sets
        // it); the toggle still asks the one rule like every other.
        let gesture = ProgressMark.markGesture(atTrueEnd: viewModel.isFinished)
        return Button {
            Task {
                // A book (by the one positive assignment of an id) takes the
                // door of the tile menu and the detail page; it ends the
                // title itself when the mark is written.
                if let active = coordinator.activeItem, active.id == viewModel.item?.id,
                   MediaFamily.kind(for: active.id) == .audiobooks {
                    if let refusal = await viewModel.markWithTheBookDoor(
                        active, coordinator: coordinator, libraryViewModel: AppSession.shared.libraryViewModel) {
                        viewModel.errorMessage = refusal
                    }
                    return
                }
                let wasFinished = viewModel.isFinished
                await viewModel.toggleFinished()
                if !wasFinished, let id = viewModel.item?.id {
                    coordinator.markPlayedAndAdvance(itemId: id)
                }
            }
        } label: {
            Label(gesture.marksPlayed ? String(localized: "Mark Finished") : String(localized: "Mark Unfinished"),
                  systemImage: gesture.marksPlayed ? "checkmark.circle" : "checkmark.circle.fill")
        }
        .font(.footnote)
        .accessibilityIdentifier("player-mark-finished")
    }

    /// Transcript. Podcast episodes only, and only when the feed's
    /// `podcast:transcript` actually parsed (no tag → no entry, silently).
    /// Shown only when `tools` says so; the decision is not repeated here.
    private var transcriptControl: some View {
        Button { showTranscript = true } label: {
            Label("Transcript", systemImage: "text.quote")
        }
        .font(.footnote)
        .accessibilityIdentifier("player-transcript")
    }

    /// Up-Next home at the player: opens the global queue (sheet). The queue is
    /// a player concept, so its entry lives HERE, not on the library tabs.
    private var queueControl: some View {
        Button { showQueue = true } label: {
            Label("Up Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        .font(.footnote)
        .accessibilityIdentifier("player-queue")
    }

    private var airPlayControl: some View {
        AirPlayButton(tintColor: .white, activeTintColor: AppTheme.accentUIColor)
            .frame(width: 44, height: 44)
    }

    /// Shown only when `tools` says so (lyrics found for the current
    /// song, server-first with the LRCLIB fallback); the decision is not
    /// repeated here.
    private var lyricsControl: some View {
        Button { showLyrics = true } label: {
            Label("Lyrics", systemImage: "quote.bubble")
        }
        .font(.footnote)
    }

    /// Shown only when `tools` says so (a source that keeps bookmarks);
    /// the decision is not repeated here.
    private var bookmarksControl: some View {
        Button { showBookmarks = true } label: {
            Label("Bookmarks", systemImage: "bookmark")
        }
        .font(.footnote)
    }

    // MARK: - Helfer

    private var chapterCounterText: String {
        guard let current = viewModel.currentChapter,
              let idx = viewModel.chapters.firstIndex(of: current) else { return "" }
        let count = viewModel.chapters.count
        // Music counts tracks, not chapters.
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
