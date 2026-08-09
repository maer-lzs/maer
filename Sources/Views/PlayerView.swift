// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import OSLog

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
    /// Up-Next home at the player: the global queue opens as a sheet from here.
    @State private var showQueue = false
    /// M4: lyrics of the CURRENT song (nil = none/still loading) + panel state.
    @State private var songLyrics: SongLyrics?
    @AppStorage(AppStorageKeys.musicLyricsOnlineLookup) private var lyricsOnline = true
    @State private var showLyrics = false
    /// V7: transcript of the CURRENT episode (nil = no tag/unparseable).
    @State private var transcript: SongLyrics?
    @State private var showTranscript = false
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
        // e3dabb3: the task id carries the opt-out — a flip re-evaluates
        // IMMEDIATELY (off drops cached web lyrics, no app restart).
        .task(id: "\(viewModel.currentMusicSong?.id ?? "-")-\(lyricsOnline)") {
            #if DEBUG
            // 84acc50: harness hook — force the FULL six-item extras row
            // (lyrics+transcript present) for the German-overflow screenshot.
            if ProcessInfo.processInfo.arguments.contains("-uitest-fullrow") {
                let dummy = SongLyrics(synced: false, lines: [LyricsLine(start: nil, text: "-")])
                songLyrics = dummy
                transcript = dummy
                return
            }
            #endif
            guard let song = viewModel.currentMusicSong else { songLyrics = nil; return }
            songLyrics = await LyricsService.shared.lyrics(
                songId: song.id, artist: song.artist, title: song.title, duration: song.duration)
        }
        .sheet(isPresented: $showLyrics) {
            if let songLyrics, let song = viewModel.currentMusicSong {
                LyricsPanel(lyrics: songLyrics, songStart: song.start, viewModel: viewModel)
            }
        }
        // V7: the transcript panel IS the lyrics panel (episode times are
        // absolute → songStart 0); entry exists only with a parsed transcript.
        .sheet(isPresented: $showTranscript) {
            if let transcript {
                LyricsPanel(lyrics: transcript, title: "Transcript",
                            songStart: 0, viewModel: viewModel)
            }
        }
        .task(id: viewModel.item?.id) {
            transcript = nil
            guard let id = viewModel.item?.id, PlayerSourceTargets.isPodcast(id),
                  let url = PodcastSubscriptions.shared.episode(guid: id)?.episode.transcriptURL,
                  !url.isEmpty else { return }
            transcript = await PodcastTranscriptService.shared.transcript(for: url)
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarksSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showQueue) {
            // The process-wide coordinator — the same instance the library
            // observes (PlayerView itself only holds the view model).
            PlayQueueSheet(playerCoordinator: AppSession.shared.playerCoordinator)
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

    @ViewBuilder
    private var cover: some View {
        Group {
            if viewModel.isLiveStream {
                if let songCover = viewModel.icySongArtwork {
                    // Teil 2: a resolved now-playing cover (MusicBrainz → Cover
                    // Art Archive) is real album art — show it full size.
                    Image(uiImage: songCover)
                        .resizable().aspectRatio(1, contentMode: .fit)
                        .transition(.opacity)
                } else {
                    // Y58: radio — never upscale a low-res favicon fullscreen. A
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
                        .overlay(Image(systemName: "book.closed").font(.largeTitle))
                }
            }
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
            if viewModel.isLiveStream {
                // F2/ICY: radio shows the STATION as the big title, with the
                // current ICY song underneath (in-app arrangement; the lock
                // screen stays song-first per Apple's convention).
                // 0aa18b7 ROOT CAUSE: this live branch rendered the station
                // as PLAIN text — the V10 tappable title only lived in the
                // else branch radio never reaches. Same wrapper now (G8:
                // plain again when the station cannot be resolved).
                sourceTappable(target: titleTarget, a11yId: "player-source-title") {
                    // 6b3a35d (4): pipe-junk trimmed for display everywhere.
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
            // X14: the WORK is the large title (shared derivation — book/episode
            // title, the song title for music). It had silently vanished from the
            // player once T9d stopped baking the work title into the chapter
            // names ("Kapitel 71 – Armageddon …"); the player never had its own
            // title line, so only the cleaned chapter ("Teil 12") was left.
            // 9aad53c: title/subtitle navigate to the source page (Apple-
            // Media convention) — book title → book detail, podcast subtitle
            // → show page, music subtitle → album page. Plain text when no
            // target resolves (radio, unresolvable ids).
            sourceTappable(target: titleTarget, a11yId: "player-source-title") {
                Text(viewModel.nowPlayingTitle)
                    .font(.title3).bold()
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            // Chapter / part line (T9c): a real chapter · author, the fallback
            // marker ("Teil 12 von 39" / "ab 3:15"), or the artist for music.
            if let subtitle = chapterSubtitle {
                sourceTappable(target: subtitleTarget, a11yId: "player-source-subtitle") {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
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
        }
        .padding(.horizontal)
    }

    /// X14: the line under the work title in the full player. For music the
    /// artist (the song is the title); for a fallback book the part/time marker
    /// (which the lock screen deliberately hides); otherwise "chapter · author".
    // MARK: - 9aad53c source navigation

    /// Gate 2: taps go through the ONE central router (environment wiring
    /// was fragile across presentation contexts — silent no-op on device).
    /// Log-first: the tap log fires BEFORE routing, so a dead device tap is
    /// distinguishable (tap logged + no route = handler lost; nothing logged
    /// = the tap never reaches the button).
    private func openPlayerSource(_ target: PlayerSourceTarget) {
        Logger.player.notice("PLAYERSOURCE tap target=\(String(describing: target), privacy: .public)")
        PlayerSourceRouter.shared.open(target)
    }

    /// Wraps a line in a Button when a source target exists; ONE context menu
    /// on the tappable line carries the further destinations (music: artist ·
    /// podcast: episode) plus the queue entry — no parallel mechanics.
    @ViewBuilder
    private func sourceTappable(target: PlayerSourceTarget?, a11yId: String,
                                @ViewBuilder content: () -> some View) -> some View {
        // G8: only offer the tap affordance when a route can actually be
        // taken — no target OR no registered router handler renders PLAIN.
        // ccc41d5: a subtle chevron marks the navigable line (discoverability
        // after the device-confirmed Gate 2); it exists ONLY together with
        // the resolvable target — the same G8 condition, one branch.
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
    /// (audiobooks) — or, V10, the STATION detail for a live radio stream
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
            if let item = AppSession.shared.libraryItem(forId: id) { return .musicAlbum(item) }
            if let detail = viewModel.item {
                return .musicAlbum(LibraryItem(id: detail.id, media: detail.media, addedAt: nil))
            }
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
                        // Best-effort name match — the playing detail carries no
                        // artist id; unresolvable stays a silent no-op.
                        let artists = (try? await AppSession.shared.musicProvider.allArtists()) ?? []
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
    /// current speed — the number night listeners actually care about.
    private func estimatedFinishTime() -> String {
        let rate = max(Double(viewModel.playbackRate), 0.1)
        let remaining = max(viewModel.duration - viewModel.currentTime, 0) / rate
        return Date().addingTimeInterval(remaining).formatted(date: .omitted, time: .shortened)
    }

    /// Teil 1: the active radio station (with its variants) — resolved from the
    /// store/session so the live quality menu can offer the codec/bitrate
    /// variants. nil for non-radio or a single-variant station (→ no menu).
    private var liveStation: RadioStation? {
        guard viewModel.isLiveStream, let id = viewModel.item?.id,
              let station = RadioProvider.shared.station(forId: id),
              station.variantList.count > 1 else { return nil }
        return station
    }

    /// F2: live radio — no scrubber, no duration; a LIVE mark plus the
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
        .padding(.horizontal, 24)
        .frame(minHeight: 44)
    }

    /// Teil 1: switch the live stream to another codec/bitrate variant — good
    /// when the current one stutters. The choice persists per station and the
    /// station re-opens at the chosen stream (the play path picks it up).
    private func qualityMenu(for station: RadioStation) -> some View {
        let selected = RadioStore.selectedVariantURL(for: station) ?? station.streamURL
        return Menu {
            ForEach(station.variantList, id: \.id) { variant in
                Button {
                    RadioStore.setSelectedVariant(variant.streamURL, for: station)
                    RadioPlay.play(station, playerCoordinator: AppSession.shared.playerCoordinator)
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

    /// d0dc536: G8 rule for row 2 — no chapters/parts ⇒ NO chapters button
    /// (a disabled ghost was a broken promise); the row closes up. Speed/
    /// skip/sleep are universal and stay.
    private var hasChapterEntry: Bool { !viewModel.chapters.isEmpty }

    private var regularSecondaryControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 32) {
                speedControl
                if hasChapterEntry { chaptersControl }
                skipIntervalControl
                sleepControl
            }
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
                // X18/X23: shared selector label — tracks for music, parts for a
                // fallback book, chapters otherwise.
                Label(ChapterModel.selectorLabel(isMusic: viewModel.isMusicItem,
                                                 isFallback: viewModel.chaptersAreFallback),
                      systemImage: "list.bullet")
            }
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

    /// a50134c ENTSCHEID (the owner 02.08.): Variante A für ALLE Medientypen —
    /// Extras-Reihe (Up Next · Lesezeichen · Lyrics [Musik] · Transcript
    /// [Podcast] · „…"-Mehr-Menü mit Fahrmodus + Als gehört) und AirPlay
    /// SOLO mittig darunter (Apple-Position). Radio läuft über dieselbe
    /// Struktur (weniger Einträge, AirPlay mittig passt überall). D2: bei
    /// AX-Größen fällt die Extras-Reihe in ein 2-Spalten-Grid.
    /// 84acc50: drive mode + mark-finished moved OUT of the "…" menu into
    /// the row — the menu emptied and is GONE. Overflow (the German-labels
    /// worst case with a full six-item row): ViewThatFits tries the labeled
    /// row first; when it cannot fit, the SAME buttons render icon-only
    /// (a11y labels intact) — never the jagged two-column grid again. With
    /// G8-gated entries missing (no lyrics/transcript), labels usually fit.
    private var tertiaryControls: some View {
        VStack(spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 36) {
                    extrasItems
                }
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

    @ViewBuilder
    private var extrasItems: some View {
        queueControl
        bookmarksControl
        lyricsControl
        transcriptControl
        driveModeControl
        markFinishedControl
        catalogSourceControl
    }

    private var driveModeControl: some View {
        Button { DriveModeController.shared.enter() } label: {
            Label("Drive Mode", systemImage: "car.fill")
        }
        .font(.footnote)
        .accessibilityIdentifier("player-drive-mode")
    }

    /// M1-Auflage (09.08.): seit die Musik-Katalog-Kacheln beim Tap SPIELEN,
    /// ueberspringt der Weg das Detail-Sheet — und dort stand die
    /// ToS-Pflichtangabe von Jamendo (Kuenstler, Anbieter, Rueckverweis).
    /// Der Player traegt sie jetzt selbst: Lizenz/Quelle sichtbar, Link zur
    /// Quellseite. Kein Katalog-Titel ⇒ keine Zeile.
    @ViewBuilder
    private var catalogSourceControl: some View {
        if let id = viewModel.item?.id,
           FreeCatalog.allPrefixes.contains(where: { id.hasPrefix($0) }) {
            let licence = FreeCatalogProvider.shared.licence(forItemId: id)
            let source = FreeCatalogProvider.shared.sourceURL(forItemId: id)
            VStack(alignment: .leading, spacing: 4) {
                if id.hasPrefix(FreeCatalog.jamendoPrefix) {
                    Label("Creative Commons — via Jamendo", systemImage: "checkmark.seal")
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
        // GT 09.08.: im Player ist das markierte Element per Definition das
        // laufende — „gehoert" muss es also anhalten (X16c). `toggleFinished`
        // allein kippt nur die Marke. Richtung ZUERST lesen, danach hat sie
        // sich schon gedreht; „ungehoert" bleibt folgenlos (Position und
        // Wiedergabe unveraendert, Auflage 3).
        Button {
            Task {
                let wasFinished = viewModel.isFinished
                await viewModel.toggleFinished()
                if !wasFinished, let id = viewModel.item?.id {
                    AppSession.shared.playerCoordinator.markPlayedAndAdvance(itemId: id)
                }
            }
        } label: {
            Label(viewModel.isFinished ? String(localized: "Mark Unfinished") : String(localized: "Mark Finished"),
                  systemImage: viewModel.isFinished ? "checkmark.circle.fill" : "checkmark.circle")
        }
        .font(.footnote)
        .accessibilityIdentifier("player-mark-finished")
    }

    /// V7: transcript — podcast episodes only, and only when the feed's
    /// `podcast:transcript` actually parsed (no tag → no entry, silently).
    @ViewBuilder
    private var transcriptControl: some View {
        if transcript != nil {
            Button { showTranscript = true } label: {
                Label("Transcript", systemImage: "text.quote")
            }
            .font(.footnote)
            .accessibilityIdentifier("player-transcript")
        }
    }

    /// Up-Next home at the player: opens the global queue (sheet) — the queue is
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
