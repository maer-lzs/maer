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
    /// The glyph of a media pill on the glyph rung. It grows with the text
    /// size up to a ceiling, and the ladder measures the row with it, so a
    /// larger glyph can never push the row past one line.
    @ScaledMetric(relativeTo: .subheadline) var pillGlyphSize: CGFloat = 17
    let onLogout: () -> Void
    @Environment(\.dismiss) private var dismiss

    // nonisolated: `ChipRowCandidate.body` reads `label` during ViewThatFits
    // measurement on the AsyncRenderer. The enum is pure
    // data, so it leaves the MainActor default explicitly.
    nonisolated enum Tab: String, CaseIterable, Identifiable {
        // Variante b: General + one pill per media type that (a) is enabled
        // and (b) HAS own settings. Today that is Audiobooks (series
        // auto-play), Podcasts (recommendations) and Music (metadata).
        //
        // Why Radio has none, written down so the question does not come
        // back: radio has no TAB-LEVEL setting. Its
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

        /// The same name as text, for the upright cell's VoiceOver label.
        var title: String {
            switch self {
            case .general: return String(localized: "General")
            case .audiobooks: return String(localized: "Audiobooks")
            case .podcasts: return String(localized: "Podcasts")
            case .music: return String(localized: "Music")
            case .radio: return String(localized: "Radio")
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

        /// The kind whose downloads this pill deletes, in its last section.
        /// General deletes only everything at once; radio has no downloads.
        var downloads: DownloadKind? {
            switch self {
            case .general, .radio: return nil
            case .audiobooks: return .audiobooks
            case .podcasts: return .podcasts
            case .music: return .music
            }
        }
    }
    @State private var tab: Tab = .general
    /// Where the system stands its bars upright: the sections then stand in
    /// the side column like the library's tabs (`TabBarPlacement`).
    @State private var verticalBarSide: VerticalBarSide?
    @State private var reservedSide = ReservedStrip()
    /// The strip's trailing edge in window points: the sheet ends short of
    /// the window's edge, and the axis is reckoned from that edge.
    @State private var stripMaxX: CGFloat = 0
    private var sectionsAtSide: Bool { TabBarPlacement.of(verticalBarSide: verticalBarSide).isSide }

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

    @State private var skipInterval: Double = AppStorageKeys.skipIntervalValue
    @State private var defaultRate: Double = Double(AppStorageKeys.defaultPlaybackRateValue)
    @State private var smartRewind: Bool =
        AppStorageKeys.smartRewindValue
    @State private var warnCellular: Bool =
        AppStorageKeys.warnCellularDownloadValue
    @State private var autoPlayNext: Bool = AppStorageKeys.autoPlayNextInSeriesValue
    @AppStorage(AppStorageKeys.appearance) private var appearance = "system"
    @AppStorage(AppStorageKeys.homeRecommendations) private var homeRecommendations = true
    // The key still says "podcast" although the switch now covers playlists
    // too. Renaming it would reset the setting of EVERY user to the default.
    // The same class as the keychain loss on a bundle-ID change, only
    // invisible. Do not "tidy" this name.
    @AppStorage(AppStorageKeys.podcastICloudSync) private var podcastICloudSync = true
    /// Whether a Mär sync service is set up (address and token). Read on
    /// appearance, not per render: the token lives in the keychain.
    @State private var maerSyncConfigured = false
    /// What the service does now, for the footer: read with the line above
    /// and again when the switch moves.
    @State private var maerSyncStanding: MaerSyncStanding = .notInUse
    /// This device refuses notifications while the switch is on: said at
    /// the switch, never silently swallowed.
    @State private var notificationsDenied = false
    @AppStorage(AppStorageKeys.podcastNewEpisodeNotifications) private var newEpisodeNotifications = false

    // TF bib-toggles: two-level library toggles. Tab masters (default ON) +
    // per-source (absAudiobooks/rss default ON; the opt-in sources default OFF).
    // Every change routes through `AppSession.reconfigureSources()`.
    @AppStorage(AppStorageKeys.audiobooksTabEnabled) private var audiobooksTab = true
    @AppStorage(AppStorageKeys.podcastsTabEnabled) private var podcastsTab = true
    @AppStorage(AppStorageKeys.musicTabEnabled) private var musicTab = true
    @AppStorage(AppStorageKeys.radioTabEnabled) private var radioTab = true

    @State private var coverCacheBytes: Int64 = 0

    /// Same speed steps as the full player's speed menu.
    private let availableRates: [Double] = [0.8, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        VStack(spacing: 0) {
            if !sectionsAtSide { pillTabs }
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
                    if DriveModeGate.isOpen { driveModeSection }
                    appearanceSection
                    statsSection
                    #if DEBUG
                    // Diagnostics only in builds from Xcode, never in a
                    // release build (TestFlight, App Store).
                    diagnosticsSection
                    #endif
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
                    // What every show follows unless it has its own, and
                    // the shows that do.
                    PodcastGeneralSection()
                    // Where the mirror's and the premium shows stand.
                    PodcastSubscriptionFoldSection()
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
                // Deleting a kind stands in its own pill, destructive last.
                if let kind = tab.downloads {
                    StorageKindSection(kind: kind)
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
            // Beside the side column the sheet closes from the column's top.
            if !sectionsAtSide {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        // Locale-independent handle for the UI-test harness.
                        .accessibilityIdentifier("settings-done")
                }
            }
        }
        .task {
            coverCacheBytes = Artwork.cacheSizeBytes()
        }
        // The sections at the bottom of the side column, the library's tab
        // bar upright, on the axis of the system's own column.
        .overlay {
            if sectionsAtSide {
                GeometryReader { proxy in
                    let strip = verticalBarSide == .leading ? proxy.safeAreaInsets.leading : proxy.safeAreaInsets.trailing
                    VStack {
                        // Where the system stands a page's back button, as
                        // the full player closes (`SideRoundButton`).
                        SideRoundButton(systemImage: "xmark", label: "Close") { dismiss() }
                            .accessibilityIdentifier("settings-close")
                        Spacer(minLength: 0)
                        sectionColumn
                    }
                    .frame(width: TabBarPlacement.sideMeasure)
                    .offset(x: reservedSide.shift(stripMaxX: stripMaxX))
                    .frame(width: max(strip, TabBarPlacement.sideMeasure + 8))
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxX } action: { stripMaxX = $0 }
                    .padding(.top, reservedSide.top)
                    .padding(.bottom, proxy.safeAreaInsets.bottom + 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: verticalBarSide == .leading ? .bottomLeading : .bottomTrailing)
                    .ignoresSafeArea()
                    .readsReservedStrip(ofWidth: strip, $reservedSide)
                }
            }
        }
        .readsVerticalBarSide($verticalBarSide)
    }

    /// The sections as the library's tab bar, upright: one cell per pill,
    /// General with the cog (decided for the column), the same handles.
    private var sectionColumn: some View {
        MediaTabBar(
            cells: visibleTabs.map { t in
                TabBarCell(id: "settings-tab-\(t.rawValue)", systemImage: t.glyph ?? "gearshape",
                           label: t.title, tint: AppTheme.accent)
            },
            selectedID: "settings-tab-\(tab.rawValue)",
            onSelectID: { id in
                guard let chosen = visibleTabs.first(where: { "settings-tab-\($0.rawValue)" == id }) else { return }
                withAnimation(.snappy(duration: 0.2)) { tab = chosen }
            },
            upright: true)
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
        let glyphSize = min(pillGlyphSize, Self.pillGlyphCeiling)
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
                             fontSize: size, glyphSize: glyphSize, accent: accent, select: select)
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

    /// The largest glyph a media pill takes, whatever the text size: the
    /// row stays one line, and five pills of a larger glyph no longer fit a
    /// small phone.
    private static let pillGlyphCeiling: CGFloat = 24

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
        /// The point size of a glyph on the glyph rung, its own and larger
        /// than the rung's text, so the glyph fills its pill.
        let glyphSize: CGFloat
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
        /// It follows the glyph, with room for the tallest symbol.
        private var glyphContentHeight: CGFloat { glyphSize + 4 }

        /// One pill's face: text on every text rung; on the glyph rung the
        /// four media pills show their tab-bar glyph while "General". Which
        /// has no honest glyph. Stays text.
        @ViewBuilder private func pillLabel(_ t: Tab) -> some View {
            if glyphMode {
                Group {
                    if let glyph = t.glyph {
                        Image(systemName: glyph)
                            .font(.system(size: glyphSize, weight: .medium))
                    } else {
                        Text(t.label)
                    }
                }
                .frame(height: glyphContentHeight)
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

    /// Section follows the button RULEBOOK: facts → toggles → actions → the
    /// destructive row last. The sizes per kind stay here as the overview,
    /// the last destructive row deletes every download; each kind is deleted
    /// in its own pill (`StorageKindSection`), and here only while its pill
    /// is gone (`StorageUnreachableKindRows`), a single title from its own
    /// context menu. The parts that read the downloads are their own leaves,
    /// in their places.
    private var storageSection: some View {
        Section {
            // Facts
            StorageDownloadSizes()
            LabeledContent {
                Text(ByteCountFormatter.string(fromByteCount: coverCacheBytes, countStyle: .file))
            } label: {
                Label("Cover Cache", systemImage: "photo")
            }
            // Toggles
            AppSwitch(isOn: $warnCellular) {
                Label("Warn When Not on Wi-Fi", systemImage: "wifi")
            }
            .onChange(of: warnCellular) { _, newValue in
                AppStorageKeys.set(newValue, for: AppStorageKeys.warnCellularDownload)
            }
            // Actions
            Button {
                Artwork.clearCache()
                coverCacheBytes = Artwork.cacheSizeBytes()
            } label: {
                Label("Clear Cover Cache", systemImage: "trash")
            }
            ReloadCatalogDataRow()
            // Destructive: a kind whose pill is gone (its tab is off) and
            // that still holds downloads, then the row that deletes every
            // download.
            StorageUnreachableKindRows(pillsShown: Set(visibleTabs.compactMap(\.downloads)))
            StorageDeleteRow(kind: nil)
        } header: {
            Text("Storage")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Clears derived caches only (catalog stock, day shelves, resolved lookups). Nothing of yours is touched; the app refetches on the next visit.")
                Text("Deleting downloads never deletes listening progress.")
            }
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
        Group {
            // The card from the first start, findable again here.
            Section {
                NavigationLink {
                    NextStepsView(absDestination: absPage)
                } label: {
                    Label("Next Steps", systemImage: "checklist")
                }
                .accessibilityIdentifier("settings-next-steps")
            }
            SourceMapCard(facts: .current) { area in
                AnyView(SourceAreaPage(area: area, absDestination: absPage))
            }
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
            Text("Which media types appear as tabs. A type off hides its tab and stops all its sources' calls. The per-source switches at their area on the map above are kept.")
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
            // The runs and counters of every sync are a diagnostic: only in
            // builds from Xcode, never in a release build.
            #if DEBUG
            NavigationLink {
                SyncHistoryView()
            } label: {
                Label("Sync History", systemImage: "clock.arrow.circlepath")
            }
            #endif
            // The same log the pill opens: notices of playback on this device.
            NavigationLink {
                NoticeLogView(notices: coordinator.notices)
            } label: {
                Label("Notices", systemImage: "text.bubble")
            }
            .accessibilityIdentifier("notice-log-page")
            NavigationLink {
                MaerSyncSettingsView()
            } label: {
                Label("Mär Sync", systemImage: "server.rack")
            }
            .accessibilityIdentifier("maer-sync-page")
            // The ONE switch covers every way across devices (decided: one
            // switch for travelling). Which way carries is visible: with the
            // Mär sync service set up, iCloud has its own row, off and
            // locked.
            let iCloud = ICloudSwitch.state(serviceConfigured: maerSyncConfigured)
            AppSwitch(isOn: $podcastICloudSync) {
                if iCloud == .free {
                    Label("iCloud", systemImage: "icloud")
                } else {
                    Label("Sync across devices", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .accessibilityIdentifier(iCloud == .free ? "icloud-switch" : "sync-switch")
            if iCloud != .free {
                AppSwitch(isOn: .constant(false)) {
                    Label {
                        HStack(spacing: 6) {
                            Text("iCloud")
                            Image(systemName: "lock.fill").font(.caption)
                                .accessibilityLabel(Text("Locked"))
                        }
                    } icon: {
                        Image(systemName: "icloud")
                    }
                }
                .disabled(true)
                .accessibilityIdentifier("icloud-switch")
                NavigationLink {
                    MaerSyncSettingsView()
                } label: {
                    Text("iCloud is off because Mär Sync carries your data. To switch to iCloud, sign out of Mär Sync.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("icloud-locked-reason")
            }
            // The failure that was invisible: when the shared budget is
            // exhausted, iCloud simply stops accepting writes. No error
            // reaches any call site, and two devices drift apart for weeks.
            // Shown where the switch is, because that is where someone looks
            // when they wonder why the two do not match.
            if let quota = AppStorageKeys.cloudQuotaViolation() {
                HintLine(systemImage: "exclamationmark.icloud") {
                    Text("iCloud refused a write on \(quota.formatted(date: .abbreviated, time: .shortened)). The shared space is full, so progress, playlists and statistics stopped syncing.")
                }
                .accessibilityIdentifier("icloud-quota-warning")
            }
        } header: {
            Text("Sync")
        } footer: {
            // What travels over the service is said only while it carries:
            // set up with the switch off, a refused token, an older service
            // or an open key change carries nothing.
            switch MaerSyncStanding.footer(standing: maerSyncStanding, signedIn: maerSyncConfigured) {
            case .travelsOverService:
                Text("Progress, the playback claim, the listening statistics, the playlists and your choices travel over your Mär sync service.")
            case .serviceStands:
                Text("Your Mär sync service is set up, but nothing travels over it now. Its page says why.")
            case .iCloud:
                Text("Covers podcast progress and Mär playlists. Both share one iCloud budget, so it is one decision, not two. Needs iCloud enabled. Server sync per service lives on its source page.")
            }
        }
        .onAppear {
            maerSyncConfigured = MaerSyncAccess.stored() != nil
            maerSyncStanding = MaerSyncStandingReader.current().standing
        }
        .onChange(of: podcastICloudSync) { _, on in
            maerSyncStanding = MaerSyncStandingReader.current().standing
            if on {
                PodcastCloudSync.shared.start()
                ListeningStatsStore.shared.start()
                MaerPlaylistCloudSync.shared.start()
                UserChoiceCloudSync.shared.start()
                PlaybackClaimSync.shared.start()
                // The seventh runner, under the same switch as the six:
                // it asks the switch itself on every round, so off needs
                // no call here, and on starts it or nudges a round.
                FeedAuthSync.shared.startIfConfigured(by: "switch")
            }
            // The switch is the third edge of the feed credentials'
            // way (the sign-in and the sign-out are the other two):
            // off takes them out of the iCloud keychain, on brings them
            // back unless a service carries them.
            PodcastFeedAuth.rewriteAll(by: "switch")
        }
    }



    private var aboutSection: some View {
        Section {
            LabeledContent {
                Text(Self.versionString)
            } label: {
                Label("Version", systemImage: "info.circle")
            }
            // The listener's own responsibility, once (`UserResponsibility`).
            Text(verbatim: UserResponsibility.sentence)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("about-responsibility")
        } header: {
            Text("About")
        } footer: {
            // The self-description that ships with the beta. The README's
            // identity in one line, not the two-month-old single-server one.
            Text("Mär is an open-source player for self-hosted audio: audiobooks, podcasts, music and internet radio in one app.")
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
                ForEach(PlaybackSkip.options(for: .spokenWord), id: \.self) { seconds in
                    Text("\(Int(seconds)) seconds").tag(seconds)
                }
            } label: {
                Label("Skip Interval", systemImage: "goforward")
            }
            .onChange(of: skipInterval) { _, newValue in
                // The setting is the spoken word's width; a playing song
                // keeps the music width of its own.
                AppStorageKeys.skipIntervalValue = newValue
                if let vm = coordinator.viewModel, vm.skipContent == .spokenWord {
                    vm.setSkipInterval(newValue)   // also updates the lock-screen buttons
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
                AppStorageKeys.defaultPlaybackRateValue = Float(newValue)
            }

            AppSwitch(isOn: $smartRewind) {
                Label("Smart Rewind", systemImage: "backward.circle")
            }
            .onChange(of: smartRewind) { _, newValue in
                AppStorageKeys.set(newValue, for: AppStorageKeys.smartRewind)
            }
        } header: {
            Text("Playback")
        } footer: {
            Text("Applies to everything that plays: books, podcasts, music, radio. Playback starts at the default speed; Smart Rewind resumes a little earlier after a longer pause.")
        }
    }

    // MARK: - Audiobooks

    private var audiobooksSection: some View {
        Section {
            AppSwitch(isOn: $autoPlayNext) {
                Label("Auto-Play Next in Series", systemImage: "play.circle")
            }
            .onChange(of: autoPlayNext) { _, newValue in
                AppStorageKeys.autoPlayNextInSeriesValue = newValue
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
            Text("Your server always comes first. Lyrics: \(NetworkServiceNames.lyrics) · artist images: \(NetworkServiceNames.artistImages) · high-res covers: \(NetworkServiceNames.hiResCovers).")
        }
    }

    /// The SOURCES page: whom may this app ask. Its own entry (the order
    /// decided it must not hide under network services); it inherits the
    /// old network-services slot in the placement rule.
    #if DEBUG
    /// The developer-diagnostics home, only in builds from Xcode: a release
    /// build does not even compile the way in (`ReleaseDiagnosticsFenceTests`).
    private var diagnosticsSection: some View {
        Section {
            NavigationLink {
                DiagnosticsView(libraryViewModel: libraryViewModel, playingID: coordinator.activeItem?.id)
            } label: {
                Label("Diagnostics", systemImage: "stethoscope")
            }
            .accessibilityIdentifier("settings-diagnostics")
        }
    }
    #endif

    private var networkServicesSection: some View {
        Section {
            NavigationLink {
                SourcesSettingsView()
            } label: {
                Label("External Sources & Privacy", systemImage: "network.badge.shield.half.filled")
            }
            .accessibilityIdentifier("settings-external-sources")
            // The MULTI-select suggestion language. It stood under Home
            // and reads as a start-screen setting there, while it filters
            // the CATALOG everywhere (rows, source pages, shelves), so
            // it belongs beside the other app-wide source questions.
            NavigationLink {
                SuggestionLanguagesView()
            } label: {
                Label("Content Languages", systemImage: "globe")
            }
            .accessibilityIdentifier("settings-suggestion-languages")
        }
    }

    private var recommendationsSection: some View {
        Section {
            // The same row as on the rows page, written through the ONE
            // path, so hiding it runs the cleanup rule there too.
            AppSwitch(isOn: Binding(
                get: { homeRecommendations },
                set: { newValue in
                    if let row = AppRows.row(key: "home.recommendations") { AppRows.setVisible(row, newValue) }
                }
            )) {
                Label("Recommendations", systemImage: "sparkles")
            }
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
            Text("Shows Recommended on Home. Suggestions are computed on this device; no listening profile leaves it. Source: \(NetworkServiceNames.appleCatalog).")
        }
    }



    /// Drive mode: choose the ONE car audio output (from the currently
    /// connected routes). Auto-start is an explicit opt-in toggle,
    /// default OFF. Without it the mode only starts from the player button.
    @State private var carRouteName = AppStorageKeys.string(AppStorageKeys.driveModeCarRouteName) ?? ""
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
                    AppStorageKeys.remove(AppStorageKeys.driveModeCarRouteUID)
                    AppStorageKeys.remove(AppStorageKeys.driveModeCarRouteName)
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
                            AppStorageKeys.set(output.uid, for: AppStorageKeys.driveModeCarRouteUID)
                            AppStorageKeys.set(output.name, for: AppStorageKeys.driveModeCarRouteName)
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
            Text("With the toggle on, drive mode starts when the chosen audio output connects while the app is running or returns to the foreground; iOS does not launch apps on a Bluetooth connection. It can always be started from the player. It is a big-button layout, not a safety feature.")
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
                    // The switch is the person's intent and travels to the
                    // other device; the permission belongs to THIS device.
                    // A refusal therefore no longer flips the switch back
                    // (that would undo the choice on both devices); it is
                    // said right here instead.
                    let granted = await PodcastRefreshService.requestAuthorization()
                    notificationsDenied = !granted
                    if granted { PodcastRefreshService.schedule() }
                }
            }
            .task {
                guard newEpisodeNotifications else { notificationsDenied = false; return }
                notificationsDenied = await PodcastRefreshService.notificationStatus() == .denied
            }
            if newEpisodeNotifications, notificationsDenied {
                HintLine(systemImage: "exclamationmark.triangle.fill") {
                    Text("This device does not allow notifications. Turn them on for Mär in the Settings app.")
                }
                .accessibilityIdentifier("notifications-denied-here")
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Checks your podcast subscriptions in the background and notifies you when new episodes are published. Requires notification permission.")
        }
    }


    private static var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
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

/// The words the storage section uses for each kind of download.
private extension DownloadKind {
    /// The kind in the one glyph table (`MediaType.systemImage`).
    var glyphKind: MediaType {
        switch self {
        case .audiobooks: .audiobooks
        case .podcasts: .podcasts
        case .music: .music
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .audiobooks: "Audiobooks"
        case .podcasts: "Podcasts"
        case .music: "Music"
        }
    }

    var deleteButton: LocalizedStringKey {
        switch self {
        case .audiobooks: "Delete Audiobook Downloads…"
        case .podcasts: "Delete Podcast Downloads…"
        case .music: "Delete Music Downloads…"
        }
    }

    var confirmationTitle: LocalizedStringKey {
        switch self {
        case .audiobooks: "Delete all audiobook downloads?"
        case .podcasts: "Delete all podcast downloads?"
        case .music: "Delete all music downloads?"
        }
    }

    var confirmationMessage: LocalizedStringKey {
        switch self {
        case .audiobooks: "All downloaded audiobooks will be removed from this device. Listening progress is kept."
        case .podcasts: "All downloaded podcast episodes will be removed from this device. Listening progress is kept."
        case .music: "All downloaded music will be removed from this device. Listening progress is kept."
        }
    }
}

/// The one grip the storage leaves below hold on the download manager; three
/// of them each wrote it themselves.
private let storageDownloads = DownloadManager.shared

/// The size facts of the storage section: the total and one line per media
/// type. It observes the download manager so a finished or deleted download
/// re-runs these lines, not the whole settings form.
struct StorageDownloadSizes: View {
    private let downloadManager = storageDownloads
    @ObservedObject private var downloadStock = DownloadManager.stock

    var body: some View {
        LabeledContent {
            Text(ByteCountFormatter.string(fromByteCount: downloadManager.totalDownloadsSize, countStyle: .file))
        } label: {
            Label("Downloads", systemImage: "arrow.down.circle")
        }
        ForEach(DownloadKind.allCases, id: \.self) { kind in
            StorageKindSize(kind: kind, indented: true)
        }
        // Downloads whose kind was never recorded (a music-prefixed title can
        // be an album or a book). No deletion per kind reaches them, only
        // their own context menu or deleting everything. Shown so they are
        // not invisible.
        let unassigned = DownloadKind.unassigned(in: downloadManager.downloadedItemIds,
                                                 recorded: downloadManager.kinds,
                                                 sole: downloadManager.soleKind(of:))
        if !unassigned.isEmpty {
            LabeledContent {
                Text(unassigned.count, format: .number)
            } label: {
                // On the text edge of the rows above: no symbol of its own,
                // the column stays empty.
                Label { Text("Not Assigned") } icon: { Image(systemName: "circle").hidden() }
            }
            .font(.subheadline)
        }
    }
}

/// The size of one kind of download: a line of the overview under General,
/// indented beneath the total, and the fact above the delete row in the
/// kind's own pill. One place counts it for both.
private struct StorageKindSize: View {
    private let downloadManager = storageDownloads
    @ObservedObject private var downloadStock = DownloadManager.stock
    let kind: DownloadKind
    let indented: Bool

    var body: some View {
        LabeledContent {
            Text(ByteCountFormatter.string(
                fromByteCount: kind.ids(in: downloadManager.downloadedItemIds, recorded: downloadManager.kinds,
                                        sole: downloadManager.soleKind(of:))
                    .reduce(0) { $0 + (downloadStock.sizeByItem[$1] ?? 0) },
                countStyle: .file))
        } label: {
            if indented {
                // The kind's glyph from the one table, so the three lines
                // read at a glance like the pills above them.
                // In the icon column with the kind's glyph, on the text edge
                // of the rows above; no indent of its own.
                Label(kind.label, systemImage: kind.glyphKind.systemImage)
            } else {
                Label("Downloads", systemImage: "arrow.down.circle")
            }
        }
        .font(indented ? .subheadline : .body)
    }
}

/// The last section of an audiobook, podcast or music pill: how much of that
/// kind lies on the device, and the row that deletes it. General keeps
/// only the overview and the row that deletes everything.
struct StorageKindSection: View {
    let kind: DownloadKind

    var body: some View {
        Section {
            StorageKindSize(kind: kind, indented: false)
            StorageDeleteRow(kind: kind)
        } header: {
            Text("Storage")
        } footer: {
            Text("Deleting downloads never deletes listening progress.")
        }
    }
}

/// The deletion rows General carries for kinds whose own pill is gone: the
/// same `StorageDeleteRow` the pill shows, one per kind that still holds
/// downloads, so turning a tab off never makes its downloads undeletable by
/// kind. Its own leaf, because it observes the downloads.
struct StorageUnreachableKindRows: View {
    private let downloadManager = storageDownloads
    @ObservedObject private var downloadStock = DownloadManager.stock
    let pillsShown: Set<DownloadKind>

    var body: some View {
        let downloaded = downloadManager.downloadedItemIds
        let kinds = DownloadKind.deletableOnlyInGeneral(pillsShown: pillsShown) { kind in
            !kind.ids(in: downloaded, recorded: downloadManager.kinds, sole: downloadManager.soleKind(of:)).isEmpty
        }
        ForEach(kinds, id: \.self) { kind in
            StorageDeleteRow(kind: kind)
        }
    }
}

/// One destructive row of the storage section, with a confirmation that names
/// what goes. With a kind it deletes that kind only: deleting the audiobooks
/// never reaches the podcasts or the music. Without one it deletes every
/// download, the only bulk deletion that also reaches titles whose kind was
/// never recorded, and its confirmation says so. It observes the download
/// manager because it is disabled while there is nothing to delete.
struct StorageDeleteRow: View {
    private let downloadManager = storageDownloads
    @ObservedObject private var downloadStock = DownloadManager.stock
    /// Nil deletes every download.
    let kind: DownloadKind?
    @State private var confirming = false

    private var ids: [String] {
        guard let kind else { return Array(downloadManager.downloadedItemIds) }
        return kind.ids(in: downloadManager.downloadedItemIds, recorded: downloadManager.kinds,
                        sole: downloadManager.soleKind(of:))
    }

    var body: some View {
        Button(role: .destructive) {
            confirming = true
        } label: {
            Label(kind?.deleteButton ?? "Delete All Downloads", systemImage: "trash")
        }
        .disabled(ids.isEmpty)
        .alert(kind?.confirmationTitle ?? "Delete all downloads?", isPresented: $confirming) {
            Button("Delete", role: .destructive) {
                guard kind != nil else { return downloadManager.deleteAllDownloads() }
                downloadManager.deleteDownloads(Set(ids))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(kind?.confirmationMessage
                 ?? "All downloads of every kind will be removed from this device, including those not assigned to a kind. Listening progress is kept.")
        }
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
