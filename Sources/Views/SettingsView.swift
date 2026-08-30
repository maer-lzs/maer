// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Central settings (Variante b): pill tabs at the top. "General" carries
/// everything cross-cutting in the placement-rule order (Sources → Libraries →
/// Free Catalogs → Playback → Sync → Storage → Notifications → Drive Mode →
/// Appearance → Statistics → Diagnostics → About), plus ONE pill per enabled
/// media type that has own settings (Audiobooks: series auto-play · Podcasts:
/// recommendations · Music: metadata). Placement rule: every
/// setting belongs to exactly one category. Source · library · playback ·
/// storage · sync · system/diagnosis; media-specific goes on its media pill,
/// cross-cutting on General (docs/components.md).
struct SettingsView: View {
    @ObservedObject var coordinator: PlayerCoordinator
    /// For reloading after a library switch. The settings are pushed from
    /// the library screen, which owns this view model.
    var libraryViewModel: LibraryViewModel? = nil
    @ObservedObject private var downloadManager = DownloadManager.shared
    let onLogout: () -> Void
    @Environment(\.dismiss) private var dismiss

    // nonisolated: `ChipRowCandidate.body` reads `label` during ViewThatFits
    // measurement on the AsyncRenderer. The enum is pure
    // data, so it leaves the MainActor default explicitly.
    nonisolated private enum Tab: String, CaseIterable, Identifiable {
        // Variante b: General + one pill per media type that (a) is enabled
        // and (b) HAS own settings. Today that is Audiobooks (series
        // auto-play), Podcasts (recommendations) and Music (metadata).
        //
        // S2 asked why Radio has none. Answer, written down so the
        // question does not come back: radio has no TAB-LEVEL setting. Its
        // source and switch live at the Radio area of the source map like
        // every other source; the logo fallback is an external SERVICE and
        // belongs on the network-services page; country and region are chosen
        // in the radio view itself, where you change them WHILE browsing.
        // Moving them into a settings pill would take them away from the
        // moment they are used. A pill with NOTHING but a link would be worse
        // than none. That reasoning held while radio had no pill content at
        // all; since the pills name the sources of their type, a radio pill
        // carries the same thing every other one does (the directory and the
        // user's own streams), and the finding behind the whole order was
        // "it bothers me EVERYWHERE". The station-scoping controls (country,
        // region) stay at the row they act on. That is a separate, deliberate
        // decision and unchanged.
        case general, audiobooks, podcasts, music, radio
        var id: String { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .general: return "General"
            case .audiobooks: return "Audiobooks"
            case .podcasts: return "Podcasts"
            case .music: return "Music"
            case .radio: return "Radio"
            }
        }

        /// THE tab bar's glyphs, one symbol source.
        /// A second symbol language would cost the recognition that makes
        /// the glyph rung work at all. General has none: it stays text
        /// (a gear would be a lie. The gear IS the settings).
        var glyph: String? {
            switch self {
            case .general: return nil
            case .audiobooks: return MediaType.audiobooks.systemImage
            case .podcasts: return MediaType.podcasts.systemImage
            case .music: return MediaType.music.systemImage
            case .radio: return MediaType.radio.systemImage
            }
        }
    }
    @State private var tab: Tab = .general

    /// Media-type pills only when the type is enabled (no dead pill for a
    /// hidden library). General is always there.
    private var visibleTabs: [Tab] {
        var tabs: [Tab] = [.general]
        if audiobooksTab { tabs.append(.audiobooks) }
        if podcastsTab { tabs.append(.podcasts) }
        if musicTab { tabs.append(.music) }
        if radioTab { tabs.append(.radio) }
        return tabs
    }

    @State private var skipInterval: Double =
        UserDefaults.standard.object(forKey: AppStorageKeys.skipInterval) as? Double ?? 30
    @State private var defaultRate: Double =
        Double(UserDefaults.standard.object(forKey: AppStorageKeys.defaultPlaybackRate) as? Float ?? 1.0)
    @State private var smartRewind: Bool =
        AppStorageKeys.smartRewindValue
    @State private var warnCellular: Bool =
        AppStorageKeys.warnCellularDownloadValue
    @State private var autoPlayNext: Bool =
        UserDefaults.standard.bool(forKey: AppStorageKeys.autoPlayNextInSeries)
    @AppStorage(AppStorageKeys.appearance) private var appearance = "system"
    @AppStorage(AppStorageKeys.homeRecommendations) private var homeRecommendations = true
    // The key still says "podcast" although the switch now covers playlists
    // too. Renaming it would reset the setting of EVERY user to the default.
    // The same class as the keychain loss on a bundle-ID change, only
    // invisible. Do not "tidy" this name.
    @AppStorage(AppStorageKeys.podcastICloudSync) private var podcastICloudSync = true
    @AppStorage(AppStorageKeys.podcastNewEpisodeNotifications) private var newEpisodeNotifications = false

    // TF bib-toggles: two-level library toggles. Tab masters (default ON) +
    // per-source (absAudiobooks/rss default ON; the opt-in sources default OFF).
    // Every change routes through `AppSession.reconfigureSources()`.
    @AppStorage(AppStorageKeys.audiobooksTabEnabled) private var audiobooksTab = true
    @AppStorage(AppStorageKeys.podcastsTabEnabled) private var podcastsTab = true
    @AppStorage(AppStorageKeys.musicTabEnabled) private var musicTab = true
    @AppStorage(AppStorageKeys.radioTabEnabled) private var radioTab = true

    @State private var coverCacheBytes: Int64 = 0
    /// What the debug lever cleared last. It says so instead of acting
    /// silently, like the cover-cache button beside it.
    @State private var clearedStores: String?
    @State private var showDeleteAllDownloads = false

    /// Same speed steps as the full player's speed menu.
    private let availableRates: [Double] = [0.8, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        VStack(spacing: 0) {
            pillTabs
            Form {
                // Variante b: General = everything cross-cutting, in the
                // placement-rule order below (the sequence in this switch IS
                // the rule. A new section takes its place in it instead of
                // being appended); one pill per media type with its specifics.
                switch tab {
                case .general:
                    sourcesSection
                    librariesSection
                    playbackSection
                    globalSyncSection
                    storageSection
                    notificationsSection
                    driveModeSection
                    appearanceSection
                    statsSection
                    networkServicesSection
                    aboutSection
                // The pill is the COMPLETE entry point of its media type:
                // its behaviour AND the sources that feed it. Before, 90 %
                // of the podcast settings lay under the sources, so one had
                // to leave the place that is about podcasts to learn how
                // podcasts behave. The sources appear as REFERENCES to the
                // one account page, never as copies.
                case .audiobooks:
                    audiobooksSection
                    MediaTypeSourcesSection(area: .audiobooks,
                                            absDestination: absPage)
                case .podcasts:
                    recommendationsSection
                    // Premium management ALWAYS visible on the pill.
                    PremiumFeedsSection()
                    // What an ACCOUNT does for podcasts stands with the
                    // podcasts, named after the account. The account page
                    // keeps address, access and the MODES (which media types
                    // it serves at all).
                    PodcastAccountBehaviour()
                    MediaTypeSourcesSection(area: .podcasts,
                                            absDestination: absPage)
                case .music:
                    musicSection
                    MediaTypeSourcesSection(area: .music,
                                            absDestination: absPage)
                case .radio:
                    MediaTypeSourcesSection(area: .radio,
                                            absDestination: absPage)
                }
            }
            .bottomBarClearance()
        }
        .onChange(of: visibleTabs) {
            // The selected media pill can disappear (library toggled off).
            if !visibleTabs.contains(tab) { tab = .general }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    // Locale-independent handle for the UI-test harness.
                    .accessibilityIdentifier("settings-done")
            }
        }
        .task {
            coverCacheBytes = ImageCache.shared.cacheSizeBytes()
        }
        .alert("Delete all downloads?", isPresented: $showDeleteAllDownloads) {
            Button("Delete", role: .destructive) {
                DownloadManager.shared.deleteAllDownloads()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All downloaded audiobooks will be removed from this device. Listening progress is kept.")
        }
    }

    // MARK: - Pill-Tabs

    private var pillTabs: some View {
        // ONE line, always. Same ViewThatFits form as the tab bar.
        //
        // And the same bomb with another fuse, defused the same way.
        // ViewThatFits measures candidates on SwiftUI's AsyncRenderer; a
        // closure capturing `self` (MainActor by project default) traps there.
        // Plain copies here, data-only candidates below.
        let tabs = visibleTabs
        let active = tab
        // Resolved HERE, on main. The measurement closure below runs on the
        // AsyncRenderer and may only capture plain copies.
        let accent = AppTheme.accent
        let select: (Tab) -> Void = { chosen in
            withAnimation(.snappy(duration: 0.2)) { tab = chosen }
        }
        // MeasuredLadder, never ViewThatFits. Same bomb,
        // same cure as the tab bar. Probes render on main; only the chosen
        // rung is built.
        // Below the smallest TEXT rung sits the GLYPH
        // rung (sentinel 0). "Allgemein" always stays text, the four media
        // pills fall back to their tab-bar glyphs. The floor question of the
        // ladder is thereby answered instead of open.
        return MeasuredLadder(rungs: Self.chipFontSizes + [ChipRowCandidate.glyphRung]) { size, _ in
            ChipRowCandidate(tabs: tabs, active: active,
                             fontSize: size, accent: accent, select: select)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// The descending ladder. Full `.subheadline` (15) first, the floor one
    /// step above the tab bar's smallest (the chips carry more padding). If
    /// even the smallest does not fit, the row overflows visibly and the
    /// journey reports it. THEN the question goes back to the user with the
    /// number, not before, and not with a silent second line as the escape.
    private static let chipFontSizes: [CGFloat] = [15, 14, 13, 12, 11]

    /// One candidate row of PLAIN data. Construction during
    /// measurement touches nothing isolated.
    ///
    /// `nonisolated` like `TabRowCandidate`: ViewThatFits
    /// evaluates the candidate's `body` on the AsyncRenderer, so under the
    /// MainActor default it was a runtime trap waiting for the same timing.
    /// The accent arrives as a stored copy. `AppTheme.accent` is a computed
    /// isolated property and may not be read from this body.
    nonisolated private struct ChipRowCandidate: View {
        let tabs: [Tab]
        let active: Tab
        let fontSize: CGFloat
        let accent: Color
        let select: (Tab) -> Void

        /// The sentinel rung below the smallest text size.
        static let glyphRung: CGFloat = 0

        private var glyphMode: Bool { fontSize == Self.glyphRung }
        /// Glyph pills keep a readable text size for the one text pill.
        private var effectiveFontSize: CGFloat { glyphMode ? 11 : fontSize }

        var body: some View {
            HStack(spacing: 8) {
                ForEach(tabs) { t in
                    Button {
                        select(t)
                    } label: {
                        pillLabel(t)
                            .font(.system(size: effectiveFontSize, weight: .medium))
                            // Whole or not at all. This is what lets the
                            // ladder's probe see that a rung does not fit
                            // (without it, SwiftUI truncates silently).
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            // The ONE capsule metric, shared with the
                            // tab bar. Active and inactive share EVERY
                            // measure. Colour carries the state, never size.
                            .padding(.vertical, TabBarMetrics.Capsule.verticalPadding)
                            // Five TEXT pills must fit
                            // 430-pt portrait. 16 pt of air per side stacked
                            // past that width, so the glyph rung won there
                            // although the text would fit with a tighter pill.
                            // 12 pt keeps the capsule shape; the ladder stays
                            // the judge (real squeezes still get glyphs).
                            .padding(.horizontal, 12)
                            .foregroundStyle(active == t ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            .background(
                                active == t ? AnyShapeStyle(accent) : AnyShapeStyle(.quaternary),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    // The glyph is DISPLAY, not
                    // semantics. The a11y label always carries the full
                    // title, in every rung.
                    .accessibilityLabel(Text(t.label))
                    // Locale-independent handle for the UI-test harness.
                    .accessibilityIdentifier("settings-tab-\(t.rawValue)")
                }
            }
        }

        /// One shared content height on the glyph rung. Symbols have
        /// differing intrinsic heights, and a pill row whose members differ
        /// by state is exactly the class the height fences guard against.
        private static let glyphContentHeight: CGFloat = 16

        /// One pill's face: text on every text rung; on the glyph rung the
        /// four media pills show their tab-bar glyph while "General". Which
        /// has no honest glyph. Stays text.
        @ViewBuilder private func pillLabel(_ t: Tab) -> some View {
            if glyphMode {
                Group {
                    if let glyph = t.glyph {
                        Image(systemName: glyph)
                    } else {
                        Text(t.label)
                    }
                }
                .frame(height: Self.glyphContentHeight)
            } else {
                Text(t.label)
            }
        }
    }

    // MARK: - Allgemein

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker(selection: $appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            } label: {
                Label("Appearance", systemImage: "circle.lefthalf.filled")
            }
            .pickerStyle(.segmented)
            // Which tile rows appear is a presentation question, so its
            // page lives here (the source question has its own entry).
            NavigationLink { RowsSettingsView() } label: {
                Label("Rows", systemImage: "rectangle.grid.1x2")
            }
            .accessibilityIdentifier("settings-rows")
        }
    }

    /// Downloads broken down per media type (each clearable).
    /// Classification via the pure PlayerSourceTargets id rules; the total
    /// line stays. Section follows the button RULEBOOK: facts → toggles →
    /// actions → ONE destructive row (dialog carries the per-type choices).
    private var downloadsByType: [(label: String, ids: [String])] {
        let ids = downloadManager.downloadedItemIds
        return [
            (String(localized: "Audiobooks"), ids.filter { PlayerSourceTargets.isBook($0) }),
            (String(localized: "Podcasts"), ids.filter { PlayerSourceTargets.isPodcast($0) }),
            (String(localized: "Music"), ids.filter { PlayerSourceTargets.isMusic($0) }),
        ]
    }

    @State private var showDeleteDownloadsDialog = false
    private var storageSection: some View {
        Section {
            // Facts
            LabeledContent {
                Text(ByteCountFormatter.string(fromByteCount: downloadManager.totalDownloadsSize, countStyle: .file))
            } label: {
                Label("Downloads", systemImage: "arrow.down.circle")
            }
            ForEach(downloadsByType, id: \.label) { group in
                LabeledContent {
                    Text(ByteCountFormatter.string(
                        fromByteCount: group.ids.reduce(0) { $0 + downloadManager.downloadSize(forItemId: $1) },
                        countStyle: .file))
                } label: {
                    Text(group.label).padding(.leading, 28)
                }
                .font(.subheadline)
            }
            LabeledContent {
                Text(ByteCountFormatter.string(fromByteCount: coverCacheBytes, countStyle: .file))
            } label: {
                Label("Cover Cache", systemImage: "photo.on.rectangle")
            }
            // Toggles
            AppSwitch(isOn: $warnCellular) {
                Label("Warn When Not on Wi-Fi", systemImage: "wifi")
            }
            .onChange(of: warnCellular) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: AppStorageKeys.warnCellularDownload)
            }
            // Actions
            Button {
                ImageCache.shared.clearCache()
                coverCacheBytes = ImageCache.shared.cacheSizeBytes()
            } label: {
                Label("Clear Cover Cache", systemImage: "trash")
            }
            // The debug lever for the DERIVED stores, so the cold state is
            // reachable by hand instead of once in 24 hours. It touches
            // NOTHING that belongs to the user; the boundary stands as a
            // list in `DerivedStores`, not in this label. It does not
            // replace the rule fingerprint either.
            Button {
                let geleert = DerivedStores.clear()
                clearedStores = geleert.isEmpty
                    ? String(localized: "Nothing to clear")
                    : geleert.joined(separator: " · ")
            } label: {
                Label("Reload Catalog Data", systemImage: "arrow.clockwise.circle")
            }
            if let clearedStores {
                Text(verbatim: clearedStores)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Destructive. ONE row, the dialog offers all/per-type.
            Button(role: .destructive) {
                showDeleteDownloadsDialog = true
            } label: {
                Label("Delete Downloads…", systemImage: "trash")
            }
            .disabled(downloadManager.downloadedItemIds.isEmpty)
            .confirmationDialog("Delete downloads?", isPresented: $showDeleteDownloadsDialog,
                                titleVisibility: .visible) {
                Button("Delete All Downloads", role: .destructive) { showDeleteAllDownloads = true }
                ForEach(downloadsByType.filter { !$0.ids.isEmpty }, id: \.label) { group in
                    Button(role: .destructive) {
                        for id in group.ids { downloadManager.deleteDownload(itemId: id) }
                    } label: {
                        Text(verbatim: "\(group.label) (\(group.ids.count))")
                    }
                }
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Deleting downloads never deletes listening progress.")
        }
    }

    /// The four former "Sources — X" sections are ONE now: the same map of
    /// areas the first screen shows, here with a filled state. That is also
    /// the way BACK to that screen, which did not exist before. And the
    /// switches live one push deeper, at their area (`SourceAreaPage`).
    /// Effective activity stays tab ∧ source (`SourceActivation`), every
    /// change routes through `AppSession.reconfigureSources()`, keys
    /// unchanged.
    @ViewBuilder
    private var sourcesSection: some View {
        SourceMapCard(facts: .current) { area in
            AnyView(SourceAreaPage(area: area, absDestination: absPage))
        }
    }

    /// The ONE Audiobookshelf page. The register and every media-type pill
    /// hand out this same closure, so the same account is literally the same
    /// destination and not a look-alike.
    private func absPage() -> AnyView {
        AnyView(ABSSourceView(coordinator: coordinator,
                              libraryViewModel: libraryViewModel,
                              onLogout: onLogout))
    }

    /// Variante b, rule category "library": the tab level of the two-level
    /// gating. Which media types appear. Same keys and reconfigure path as
    /// before; the per-source switches stay at their area on the map above.
    private var librariesSection: some View {
        Section {
            tabMasterToggle("Audiobooks", isOn: $audiobooksTab)
                .accessibilityIdentifier("tab-master-audiobooks")
            tabMasterToggle("Podcasts", isOn: $podcastsTab)
                .accessibilityIdentifier("tab-master-podcasts")
            tabMasterToggle("Music", isOn: $musicTab)
                .accessibilityIdentifier("tab-master-music")
            tabMasterToggle("Radio", isOn: $radioTab)
                .accessibilityIdentifier("tab-master-radio")
        } header: {
            Text("Libraries")
        } footer: {
            Text("Which media types appear as tabs. A type off hides its tab and stops all its sources' calls — the per-source switches at their area on the map above are kept.")
        }
    }

    /// TF bib-toggles: the tab-master row (bold). Flipping it reconfigures.
    private func tabMasterToggle(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        AppSwitch(isOn: isOn) { Text(title).fontWeight(.semibold) }
            .onChange(of: isOn.wrappedValue) { AppSession.shared.reconfigureSources() }
    }

    /// Etappe E: the GLOBAL sync section. The history shows all services, so
    /// it lives tab-independent; per-source sync buttons sit on the source
    /// pages (one pattern, no scattered "Sync Now" variants).
    private var globalSyncSection: some View {
        Section {
            NavigationLink {
                SyncHistoryView()
            } label: {
                Label("Sync History", systemImage: "clock.arrow.circlepath")
            }
            AppSwitch(isOn: $podcastICloudSync) {
                Label("Sync via iCloud", systemImage: "icloud")
            }
            .onChange(of: podcastICloudSync) { _, on in
                if on {
                    PodcastCloudSync.shared.start()
                    ListeningStatsStore.shared.start()
                    MaerPlaylistCloudSync.shared.start()
                    UserChoiceCloudSync.shared.start()
                    PlaybackClaimSync.shared.start()
                }
            }
            // The failure that was invisible: when the shared budget is
            // exhausted, iCloud simply stops accepting writes. No error
            // reaches any call site, and two devices drift apart for weeks.
            // Shown where the switch is, because that is where someone looks
            // when they wonder why the two do not match.
            if let quota = AppStorageKeys.cloudQuotaViolation() {
                Label {
                    Text("iCloud refused a write on \(quota.formatted(date: .abbreviated, time: .shortened)) — the shared space is full, so progress, playlists and statistics stopped syncing.")
                        .font(.footnote)
                } icon: {
                    Image(systemName: "exclamationmark.icloud")
                }
                .foregroundStyle(.orange)
                .accessibilityIdentifier("icloud-quota-warning")
            }
        } header: {
            Text("Sync")
        } footer: {
            Text("Covers podcast progress and Mär playlists — both share one iCloud budget, so it is one decision, not two. Needs iCloud enabled. Server sync per service lives on its source page.")
        }
    }



    private var aboutSection: some View {
        Section {
            LabeledContent {
                Text(Self.versionString)
            } label: {
                Label("Version", systemImage: "info.circle")
            }
        } header: {
            Text("About")
        } footer: {
            // The self-description that ships with the beta. The README's
            // identity in one line, not the two-month-old single-server one.
            Text("Mär is an open-source player for self-hosted audio — audiobooks, podcasts, music and internet radio in one app.")
        }
    }

    // MARK: - Wiedergabe (cross-cutting)

    /// Skip interval, default speed and Smart Rewind feed the
    /// lock screen and the control centre for EVERY kind of playback. Podcast,
    /// music, radio. They used to render only under `case .audiobooks`, so
    /// someone who wanted a 15-second skip for podcasts had to look under
    /// Audiobooks, and someone who switched the audiobook pill off (no books)
    /// lost access to a setting that governs their podcasts. Cross-cutting
    /// belongs on General. `autoPlayNextInSeries` stays with the books. That
    /// one really is book-specific.
    private var playbackSection: some View {
        Section {
            Picker(selection: $skipInterval) {
                ForEach([15.0, 30.0, 60.0], id: \.self) { seconds in
                    Text("\(Int(seconds)) seconds").tag(seconds)
                }
            } label: {
                Label("Skip Interval", systemImage: "goforward")
            }
            .onChange(of: skipInterval) { _, newValue in
                if let vm = coordinator.viewModel {
                    vm.setSkipInterval(newValue)   // also updates the lock-screen buttons
                } else {
                    UserDefaults.standard.set(newValue, forKey: AppStorageKeys.skipInterval)
                }
            }

            Picker(selection: $defaultRate) {
                ForEach(availableRates, id: \.self) { rate in
                    Text("\(rate.formatted(.number.precision(.fractionLength(0...2))))×").tag(rate)
                }
            } label: {
                Label("Default Speed", systemImage: "speedometer")
            }
            .onChange(of: defaultRate) { _, newValue in
                UserDefaults.standard.set(Float(newValue), forKey: AppStorageKeys.defaultPlaybackRate)
            }

            AppSwitch(isOn: $smartRewind) {
                Label("Smart Rewind", systemImage: "backward.circle")
            }
            .onChange(of: smartRewind) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: AppStorageKeys.smartRewind)
            }
        } header: {
            Text("Playback")
        } footer: {
            Text("Applies to everything that plays — books, podcasts, music, radio. Playback starts at the default speed; Smart Rewind resumes a little earlier after a longer pause.")
        }
    }

    // MARK: - Audiobooks

    private var audiobooksSection: some View {
        Section {
            AppSwitch(isOn: $autoPlayNext) {
                Label("Auto-Play Next in Series", systemImage: "play.circle")
            }
            .onChange(of: autoPlayNext) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: AppStorageKeys.autoPlayNextInSeries)
            }
        } header: {
            Text("Books")
        } footer: {
            Text("When a series book ends, the next unfinished one starts automatically.")
        }
    }

    // MARK: - Podcasts

    /// Variante b: recommendations live on the Podcasts pill (the Discover
    /// engine is podcast-driven). Still ONE opt-out for both Home sections
    /// (Rediscover + Discover). Key unchanged.
    /// The provider-WIDE music feature toggles. Moved off the
    /// Subsonic SOURCE page (feature ≠ access; they apply to Jellyfin too).
    /// Same AppStorage keys, one truth.
    @AppStorage(AppStorageKeys.musicLyricsOnlineLookup) private var lyricsOnline = true
    @AppStorage(AppStorageKeys.musicHighResCovers) private var highResCovers = true
    @AppStorage(AppStorageKeys.musicArtistImagesOnline) private var artistImagesOnline = true
    private var musicSection: some View {
        Section {
            AppSwitch("Look up lyrics online", isOn: $lyricsOnline)
                .accessibilityIdentifier("music-lyrics-toggle")
            AppSwitch("Load artist images from the web", isOn: $artistImagesOnline)
            AppSwitch("High-res covers (Cover Art Archive)", isOn: $highResCovers)
        } header: {
            Text("Metadata")
        } footer: {
            // Every toggle names its exact services. The SAME
            // shared strings the network-services page shows (one truth).
            Text("Your server always comes first. Sources: lyrics — \(NetworkServiceNames.lyrics) · artist images — \(NetworkServiceNames.artistImages) · high-res covers — \(NetworkServiceNames.hiResCovers).")
        }
    }

    /// The SOURCES page: whom may this app ask. Its own entry (the order
    /// decided it must not hide under network services); it inherits the
    /// old network-services slot in the placement rule.
    private var networkServicesSection: some View {
        Section {
            NavigationLink {
                SourcesSettingsView()
            } label: {
                Label("External Sources & Privacy", systemImage: "network.badge.shield.half.filled")
            }
            .accessibilityIdentifier("settings-external-sources")
        }
    }

    private var recommendationsSection: some View {
        Section {
            AppSwitch(isOn: $homeRecommendations) {
                Label("Recommendations", systemImage: "sparkles")
            }
            // The MULTI-select suggestion language. Explicit choice
            // beats the locale guess; catalog/recommendation requests only.
            NavigationLink {
                SuggestionLanguagesView()
            } label: {
                Label("Suggestion Languages", systemImage: "globe")
            }
            .accessibilityIdentifier("settings-suggestion-languages")
            // The release path. "not interested" is permanent, so
            // there must be a place where the decision can be taken back.
            NavigationLink {
                HiddenRecommendationsView()
            } label: {
                Label("Hidden Recommendations", systemImage: "hand.thumbsdown")
            }
            .accessibilityIdentifier("settings-hidden-recommendations")
        } header: {
            Text("Home")
        } footer: {
            Text("Shows the Rediscover and Discover sections on Home. Suggestions are computed on this device; no listening profile leaves it. Source: \(NetworkServiceNames.appleCatalog).")
        }
    }



    /// Drive mode: choose the ONE car audio output (from the currently
    /// connected routes). Auto-start is an explicit opt-in toggle,
    /// default OFF. Without it the mode only starts from the player button.
    @State private var carRouteName = UserDefaults.standard.string(forKey: AppStorageKeys.driveModeCarRouteName) ?? ""
    @AppStorage(AppStorageKeys.driveModeAutoStart) private var driveModeAutoStart = false
    private var driveModeSection: some View {
        Section {
            if !carRouteName.isEmpty {
                LabeledContent {
                    Text(carRouteName)
                } label: {
                    Label("Car audio", systemImage: "car.fill")
                }
                AppSwitch(isOn: $driveModeAutoStart) {
                    Text("Start automatically when \(carRouteName) connects")
                }
                // Rulebook: destructive-class action, red, LAST row.
                Button(role: .destructive) {
                    UserDefaults.standard.removeObject(forKey: AppStorageKeys.driveModeCarRouteUID)
                    UserDefaults.standard.removeObject(forKey: AppStorageKeys.driveModeCarRouteName)
                    carRouteName = ""
                } label: {
                    Text("Forget car audio")
                }
            } else {
                // EXTERNAL routes only (the built-in speaker used to
                // crowd the list as a pointless choice) + log-first
                // enumeration; connected device → ONE prominent remember tap.
                let outputs = DriveModeController.pickerCandidates()
                if outputs.isEmpty {
                    // The list now also carries the PAIRED devices
                    // from availableInputs. So this only shows when nothing
                    // is paired/in range at all.
                    Text("Devices appear as soon as they are paired and in range.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(outputs, id: \.uid) { output in
                        Button {
                            UserDefaults.standard.set(output.uid, forKey: AppStorageKeys.driveModeCarRouteUID)
                            UserDefaults.standard.set(output.name, forKey: AppStorageKeys.driveModeCarRouteName)
                            carRouteName = output.name
                        } label: {
                            Label("Remember \(output.name) as car audio", systemImage: "car.fill")
                                .font(.body.weight(.semibold))
                        }
                        .accessibilityIdentifier("drive-remember-route")
                    }
                }
            }
        } header: {
            Text("Drive Mode")
        } footer: {
            // Honest limit: iOS does not launch apps on a Bluetooth
            // connect. Auto-start works while the app runs / comes to the
            // foreground. No false promises.
            Text("With the toggle on, drive mode starts when the chosen audio output connects while the app is running or returns to the foreground — iOS does not launch apps on a Bluetooth connection. It can always be started from the player. It is a big-button layout, not a safety feature.")
        }
    }

    /// Statistics moved from the Audiobooks pill to General. Labelled with
    /// their source (today only Audiobookshelf listening data).
    private var statsSection: some View {
        Section {
            NavigationLink {
                StatsView(libraryViewModel: libraryViewModel)
            } label: {
                Label("Statistics", systemImage: "chart.bar.fill")
            }
        } footer: {
            Text("Listening statistics come from Audiobookshelf.")
        }
    }

    /// Tab-independent Notifications section (moved off the removed Podcasts
    /// pill). The podcast new-episode toggle lives here, future notification
    /// settings join it.
    private var notificationsSection: some View {
        Section {
            AppSwitch(isOn: $newEpisodeNotifications) {
                Label("Notify About New Episodes", systemImage: "bell")
            }
            .onChange(of: newEpisodeNotifications) { _, on in
                guard on else { return }
                Task {
                    let granted = await PodcastRefreshService.requestAuthorization()
                    if !granted { newEpisodeNotifications = false }
                    else { PodcastRefreshService.schedule() }
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Checks your podcast subscriptions in the background and notifies you when new episodes are published. Requires notification permission.")
        }
    }


    private static var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
        // Build stamp: the short git SHA of the BUILT state (stamped into the
        // Info.plist by the "Stamp git SHA" build phase). Device tests are now
        // unambiguously attributable to a commit (a stale incremental build
        // shows its old SHA instead of silently masquerading as the fix).
        if let sha = Bundle.main.object(forInfoDictionaryKey: "GitSHA") as? String, !sha.isEmpty {
            return "\(version) (\(build)) · \(sha)"
        }
        return "\(version) (\(build))"
    }
}

/// The release path for "not interested": every hidden show by name, one tap
/// brings it back into the pool (the next refresh may recommend it again).
struct HiddenRecommendationsView: View {
    @ObservedObject private var store = PodcastRecommendationsStore.shared

    var body: some View {
        List {
            if store.hiddenByFeed.isEmpty {
                Text("Nothing hidden. Choosing \u{2018}Not interested\u{2019} on a recommendation puts it here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.hiddenByFeed.sorted(by: { $0.value < $1.value }), id: \.key) { feed, title in
                    HStack {
                        Text(verbatim: title)
                        Spacer()
                        Button("Allow again") {
                            store.unhide(normalizedFeed: feed)
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .navigationTitle("Hidden Recommendations")
        .navigationBarTitleDisplayMode(.inline)
    }
}
