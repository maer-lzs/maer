// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import OSLog

/// F4: the radio tab. On top, the user's own stations (favorites + last-heard
/// rows). Below, the catalog browse layer (F4-discovery): Popular, From your
/// region, and curated genres — all net-gated, so offline the tab falls back to
/// the cached favorites/recents and nothing breaks. Stations play directly
/// (F3: play replaces the active playback, never queued).
struct RadioView: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    var isActive: Bool = true
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    // User's own stations (UserDefaults-backed store).
    @State private var favorites: [RadioStation] = []
    @State private var recents: [RadioStation] = []
    // Teil 3: stations ranked by play frequency (net-independent — from the store).
    @State private var mostPlayed: [RadioStation] = []
    /// cb2d1ed: the merged first row, and its full stock for the counting head.
    @State private var myStations: [RadioStation] = []
    @State private var myStationsTotal = 0
    /// Measured seconds per station — the card line's second state.
    @State private var radioSeconds: [String: Int] = [:]
    // Catalog browse — cached per session, re-fetched only on refresh.
    @State private var popular: [RadioStation] = []
    @State private var copiedLogoReport = false
    @State private var regional: [RadioStation] = []
    @State private var discoveryLoaded = false
    /// Fourth instance of the throw-is-not-the-end class, mild form: the
    /// fetches swallowed their errors and `discoveryLoaded` was set
    /// unconditionally — a failed first run counted as "loaded", and the
    /// empty text advised searching a catalog that had simply not arrived.
    @State private var discoveryFailed = false
    private let localeCode = RadioCatalog.deviceRegionCode()
    /// The ONE user-chosen state (persisted); nil = not chosen yet. Plain
    /// state + manual defaults I/O (an optional-String @AppStorage misbehaved
    /// in the harness bisect).
    @State private var chosenState: String? = UserDefaults.standard.string(forKey: AppStorageKeys.radioRegionState)
    /// Curated picker list (b942da6): merged variants, noise filtered,
    /// sorted by station count.
    @State private var availableStates: [RadioBrowseCuration.Curated] = []
    @State private var showRegionPicker = false
    @State private var showCountryPicker = false
    /// b1ab99d cascade: explicit country choice (a) and the country implied
    /// by the chosen region (b); locale stays the last fallback (c).
    @State private var chosenCountryCode: String? = UserDefaults.standard.string(forKey: AppStorageKeys.radioChosenCountryCode)
    @State private var chosenCountryName: String? = UserDefaults.standard.string(forKey: AppStorageKeys.radioChosenCountryName)
    @State private var impliedCountryCode: String? = UserDefaults.standard.string(forKey: AppStorageKeys.radioRegionCountryCode)
    /// P12: the NATIONAL row's own country — independent of the region.
    @State private var nationalCountryCode: String? = UserDefaults.standard.string(forKey: AppStorageKeys.radioNationalCountryCode)
    @State private var nationalCountryName: String? = UserDefaults.standard.string(forKey: AppStorageKeys.radioNationalCountryName)
    /// Which row a country choice applies to (the picker serves both).
    @State private var countryPickerTarget: CountryPickerTarget = .national

    enum CountryPickerTarget { case national, region }
    #if DEBUG
    @State private var seedRegionApplied = false
    #endif

    /// USER CHOICE BEATS GUESSING (b1ab99d): the ONE country code feeding
    /// "Popular in …" and the region list.
    private var effectiveCountryCode: String? {
        RadioCountryCascade.effectiveCode(explicit: chosenCountryCode,
                                          regionImplied: impliedCountryCode,
                                          locale: localeCode)
    }

    /// P12: the NATIONAL row's country. Own choice first; without one the
    /// shared cascade — that IS the migration: whoever never decouples sees
    /// exactly today's behaviour, without a jump on first launch.
    private var nationalEffectiveCode: String? {
        RadioCountryCascade.nationalCode(explicitNational: nationalCountryCode,
                                         shared: effectiveCountryCode)
    }

    /// The REGION row's country (its own cascade step, unchanged): the
    /// country implied by the chosen region, else the shared cascade.
    /// Q5b sweep: every consumer of the OLD shared cascade was walked and
    /// assigned to a layer. Everything below reads one of the two named
    /// properties — `effectiveCountryCode` itself is the shared FALLBACK and
    /// is not read directly by any surface any more.
    private var regionEffectiveCode: String? { effectiveCountryCode }

    /// English country name for the Radio Browser states path.
    private var effectiveCountryName: String? {
        if let chosenCountryName, !chosenCountryName.isEmpty { return chosenCountryName }
        if let implied = UserDefaults.standard.string(forKey: AppStorageKeys.radioRegionCountryName),
           !implied.isEmpty { return implied }
        guard let code = effectiveCountryCode else { return nil }
        return Locale(identifier: "en_US").localizedString(forRegionCode: code)
    }

    /// "Popular in Switzerland" — follows the NATIONAL row's country (Q5b:
    /// this read the shared cascade while the row's CONTENT already followed
    /// the decoupled one, so the heading said Germany over Swiss stations).
    private var nationalTitle: String {
        guard let code = nationalEffectiveCode,
              let name = Locale.current.localizedString(forRegionCode: code) else {
            return String(localized: "Popular Stations")
        }
        return String(localized: "Popular in \(name)")
    }

    private var showsPopular: Bool { RadioCatalog.showsPopular(isConnected: networkMonitor.isConnected, popular: popular) }
    private var showsRegion: Bool { RadioCatalog.showsRegion(isConnected: networkMonitor.isConnected, regionCode: regionEffectiveCode, regional: regional) }
    private var showsGenres: Bool { RadioCatalog.showsGenres(isConnected: networkMonitor.isConnected) }
    private var hasAnyContent: Bool {
        !myStations.isEmpty || !recents.isEmpty || showsPopular || showsRegion || showsGenres
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                // cb2d1ed: "My Stations" (favorites + most played) is the
                // first row and a CARD; "Recently Played" sits below it as a
                // small tile.
                //
                // The reason they stay apart is the owner's: recently played is a
                // STATE, my stations is a PREFERENCE — two truths do not
                // belong in one row. And because the last-heard station is
                // usually also the most-heard one, the upper row leaves it
                // out: it is not gone, it stands one row lower. Behind the
                // chevron it reappears — there is no neighbouring row there.
                if !myStations.isEmpty {
                    RadioFeaturedCardRow(title: String(localized: "My Stations"),
                                         stations: myStations,
                                         playerCoordinator: playerCoordinator,
                                         favoriteIDs: Set(favorites.map(\.id)),
                                         seconds: radioSeconds,
                                         destination: .myStations,
                                         total: myStationsTotal)
                }
                if !recents.isEmpty {
                    // the owner's correction to cb2d1ed ("Zuletzt gespielt ist
                    // eine Kachelreihe"): the whole recent list, as the plain
                    // tile row — not the single last station. Deliberately
                    // small, and it carries NO show line: for a station that
                    // is no longer running it would be stale anyway.
                    cardRow(title: String(localized: "Recently Played"), stations: recents)
                }
                if showsPopular {
                    VStack(alignment: .leading, spacing: 4) {
                        VStack(alignment: .leading, spacing: 8) {
                            // 3f73f15: the browse rows carry the counting
                            // heading and a full page — every row is a
                            // preview, and this preview has a page behind it.
                            RowHeading<RadioRoute>(
                                title: "", verbatimTitle: nationalTitle,
                                total: popular.count,
                                destination: .stationList(title: nationalTitle, stations: popular))
                            browseCardScroller(stations: popular)
                        }
                        // e4bd910 Zuschnitts-Korrektur: the country switch
                        // follows the REGION pattern exactly — a "Change
                        // country" link under the section (no ▾ on the
                        // title), same style/position as "Change region";
                        // ONE mechanism (the existing cascade) behind both.
                        Button {
                            // P12: this link sits under the NATIONAL row and
                            // therefore changes only its country.
                            countryPickerTarget = .national
                            showCountryPicker = true
                        } label: {
                            Text("Change Country")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                        .accessibilityIdentifier("radio-country-change-inline")
                    }
                }
                regionSection
                if showsGenres {
                    genreSection
                }
                logoDiagnosisSection
                if !hasAnyContent {
                    if discoveryFailed {
                        // A failed load is not "no stations" — the old advice
                        // ("search the catalog") pointed at a catalog that had
                        // simply not arrived.
                        ContentUnavailableView {
                            Label("Radio", systemImage: "dot.radiowaves.left.and.right")
                        } description: {
                            Text("This could not be loaded. Check your connection.")
                        } actions: {
                            Button("Retry") { Task { await loadDiscovery(force: true) } }
                        }
                        .padding(.top, 60)
                    } else if networkMonitor.isConnected && !discoveryLoaded {
                        HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                            .frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        emptyState
                    }
                }
            }
            .padding(.top, TabContentLayout.topInset)
            .bottomBarClearance()
        }
        .reportsBottomBarScroll(active: isActive)
        .refreshable { await loadDiscovery(force: true) }
        .task(id: "\(isActive)-\(playerCoordinator.activeItem?.id ?? "")") {
            reload()
            await loadDiscovery()
        }
        // b1ab99d: region picker as a sheet (search field + country layer).
        .sheet(isPresented: $showCountryPicker) {
            NavigationStack {
                RadioCountryPickerList { code, name in
                    showCountryPicker = false
                    switch countryPickerTarget {
                    case .national: chooseNationalCountry(code: code, name: name)
                    case .region: chooseCountry(code: code, name: name)
                    }
                }
            }
        }
        .sheet(isPresented: $showRegionPicker) {
            RadioRegionPickerSheet(states: availableStates,
                                   countryTitle: regionCountryDisplayName,
                                   onChooseRegion: chooseRegion,
                                   onChooseCountry: chooseCountry)
        }
    }

    /// Localized display name of the effective country (sheet subtitle).
    private var nationalCountryDisplayName: String? {
        nationalEffectiveCode.flatMap { Locale.current.localizedString(forRegionCode: $0) }
    }

    /// The REGION row's country name, for its own picker layer.
    private var regionCountryDisplayName: String? {
        regionEffectiveCode.flatMap { Locale.current.localizedString(forRegionCode: $0) }
    }

    // MARK: - Sections

    private func listSection(title: String, stations: [RadioStation]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3).bold().padding(.horizontal)
            LazyVStack(spacing: 0) {
                ForEach(stations) { station in
                    RadioStationRow(station: station, playerCoordinator: playerCoordinator,
                                    onFavoriteToggled: reload)
                    Divider().padding(.leading, 88)
                }
            }
        }
    }

    /// Regel 2: the row itself is the shared `RadioCardRow` (also on Home).
    private func cardRow(title: String, stations: [RadioStation]) -> some View {
        RadioCardRow(title: title, stations: stations,
                     playerCoordinator: playerCoordinator,
                     onFavoriteToggled: reload)
    }

    /// The card strip WITHOUT its own title — the counted RowHeading above
    /// carries title and page entry (3f73f15).
    private func browseCardScroller(stations: [RadioStation]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(RowPreview.cut(stations)) { station in
                    RadioStationCard(station: station, playerCoordinator: playerCoordinator,
                                     onFavoriteToggled: reload)
                }
            }
            .padding(.horizontal)
        }
    }

    /// The cover report is only reproducible on a device, and reading the
    /// device log needs a Mac, a cable and root. This makes the same answer
    /// copyable from the phone itself — it reads the STORED state and never
    /// re-runs the chain, because a diagnosis that changes what it measures is
    /// worthless. Diagnostic UI stays verbatim (project convention).
    @ViewBuilder
    private var logoDiagnosisSection: some View {
        if !popular.isEmpty || !regional.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    // Every station this session has SEEN, not just the two
                    // rows on this screen: the genre pages are exactly where
                    // stations appear that were never played, and those are
                    // the ones the question is about. Measuring the wrong set
                    // is how a diagnosis reports a confident zero.
                    let shown = RadioProvider.shared.sessionStations.values
                        .map { (id: $0.id, name: $0.name, faviconURL: $0.faviconURL) }
                    let base = RadioLogoReport.text(
                        RadioLogoReport.rows(stations: shown,
                                             chainResults: RadioLogoService.storedOutcomes(),
                                             now: Date().timeIntervalSince1970))
                    UIPasteboard.general.string = base
                    copiedLogoReport = true
                    // The display half needs to LOAD, so it lands a moment
                    // later — the summary above is already in the clipboard,
                    // and this replaces it once the pictures answered.
                    Task {
                        let urls = RadioLogoService.storedURLs()
                        let names = Dictionary(shown.map { ($0.id, $0.name) },
                                               uniquingKeysWith: { a, _ in a })
                        var loaded: [RadioLogoReport.Loaded] = []
                        for (id, url) in urls.sorted(by: { $0.key < $1.key })
                        where names[id] != nil {
                            if loaded.count >= 12 { break }
                            let image = await ImageCache.shared.thumbnail(for: url)
                            let width = Int((image?.size.width ?? 0) * (image?.scale ?? 1))
                            let height = Int((image?.size.height ?? 0) * (image?.scale ?? 1))
                            let verdict: String
                            if image == nil { verdict = "laedt nicht" }
                            else if !RadioFaviconGate.acceptableTouchIcon(pixelWidth: width,
                                                                          pixelHeight: height) {
                                verdict = "verworfen"
                            } else { verdict = "angezeigt" }
                            loaded.append(RadioLogoReport.Loaded(
                                name: names[id] ?? id, url: url.absoluteString,
                                pixels: image == nil ? "—" : "\(width)x\(height)",
                                verdict: verdict))
                        }
                        UIPasteboard.general.string = base + RadioLogoReport.loadedText(loaded)
                    }
                } label: {
                    Label {
                        Text(verbatim: "Logo-Diagnose kopieren")
                    } icon: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .font(.footnote)
                }
                .accessibilityIdentifier("radio-logo-diagnosis-copy")
                if copiedLogoReport {
                    Text(verbatim: "In die Zwischenablage gelegt.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .foregroundStyle(.secondary)
        }
    }

    private var genreSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            RowHeading.plain("By Genre")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                      spacing: 12) {
                ForEach(RadioCatalog.genres) { genre in
                    NavigationLink(value: RadioRoute.genre(tag: genre.tag, title: genre.title)) {
                        HStack(spacing: 12) {
                            Image(systemName: genre.systemImage)
                                .font(.title2)
                                .foregroundStyle(AppTheme.accent)
                                .frame(width: 28)
                            Text(genre.title).font(.body.weight(.medium)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.primary.opacity(0.06)))
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("radio-genre-\(genre.tag)")
                }
            }
            .padding(.horizontal)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No stations yet", systemImage: "dot.radiowaves.left.and.right")
        } description: {
            Text("Search the catalog with the magnifier and star your stations — or add a stream URL under Settings → Areas → Radio.")
        }
        .padding(.top, 60)
    }

    // MARK: - Loading

    private func reload() {
        let favs = RadioStore.favorites()
        // cb2d1ed: NO longer filtered against the favorites — row 2 shows the
        // station that actually ran last, whether it is starred or not. The
        // de-duplication now happens the other way round: the row ABOVE leaves
        // this one out.
        let recs = RadioStore.recents()
        let secs = ListeningStatsStore.shared.radioSeconds()
        let most = RadioStore.mostPlayed(seconds: secs)
        let excluded = RadioMyStations.excludedID(recents: recs)
        let mine = RadioMyStations.composed(favorites: favs, mostPlayed: most,
                                            seconds: secs, excluding: excluded,
                                            limit: .max)
        // Layout-shift: same calm gate as loadDiscovery — the per-section
        // empty→filled rule applies to the library rows too (user-driven calls
        // run while calm, so they still apply instantly).
        BottomBarState.shared.runWhenCalm { [self] in
            favorites = favs
            recents = recs
            mostPlayed = most
            radioSeconds = secs
            myStations = mine
            myStationsTotal = mine.count
        }
    }

    /// Fetch the catalog rows once per session (guarded), re-fetched on refresh.
    /// Net-gated: offline it does nothing and the sections stay hidden.
    /// Region = the user-chosen state: before the choice a small picker
    /// entry (never an empty list, never a second national section); a
    /// country without states hides the section silently.
    @ViewBuilder
    private var regionSection: some View {
        if let chosenState, !chosenState.isEmpty {
            // 71b277f (A): the section NEVER vanishes while loading — right
            // after the pick (regional still empty) the title stays with a
            // small inline indicator instead of a seconds-long blank.
            if regional.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text(chosenState).font(.title3).bold()
                        ProgressView().controlSize(.small)
                    }
                    .padding(.horizontal)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    VStack(alignment: .leading, spacing: 8) {
                        RowHeading<RadioRoute>(
                            title: "", verbatimTitle: chosenState,
                            total: regional.count,
                            destination: .stationList(title: chosenState, stations: regional))
                        browseCardScroller(stations: regional)
                    }
                    Button {
                        self.chosenState = nil
                        UserDefaults.standard.removeObject(forKey: AppStorageKeys.radioRegionState)
                        UserDefaults.standard.removeObject(forKey: AppStorageKeys.radioRegionQueryNames)
                        regional = []
                        // Refill the picker list immediately — without this the
                        // section went DEAD until restart (confirmed regression).
                        Task { await loadDiscovery(force: true) }
                    } label: {
                        Text("Change region")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    // Locale-independent handle for the UI-test harness.
                    .accessibilityIdentifier("radio-region-change")
                }
            }
        } else if !availableStates.isEmpty, networkMonitor.isConnected {
            VStack(alignment: .leading, spacing: 8) {
                RowHeading.plain("From Your Region")
                // b1ab99d: the picker is a SHEET now — a Menu cannot carry the
                // required search field or the country layer.
                Button {
                    showRegionPicker = true
                } label: {
                    Label("Choose your region", systemImage: "mappin.and.ellipse")
                        .padding(.horizontal)
                }
                .accessibilityIdentifier("radio-region-picker")
            }
        }
    }

    /// Region choice: persist display name + ALL merged raw names (the query
    /// runs against every variant) + the implied country (cascade step b).
    /// P12: the NATIONAL choice — writes only its own keys, the region row
    /// stays untouched (that is the whole point of the decoupling).
    private func chooseNationalCountry(code: String, name: String) {
        nationalCountryCode = code
        nationalCountryName = name
        UserDefaults.standard.set(code, forKey: AppStorageKeys.radioNationalCountryCode)
        UserDefaults.standard.set(name, forKey: AppStorageKeys.radioNationalCountryName)
        Task { await loadDiscovery(force: true) }
    }

    private func chooseRegion(_ entry: RadioBrowseCuration.Curated) {
        chosenState = entry.display
        UserDefaults.standard.set(entry.display, forKey: AppStorageKeys.radioRegionState)
        UserDefaults.standard.set(entry.queryNames, forKey: AppStorageKeys.radioRegionQueryNames)
        if let code = regionEffectiveCode {
            impliedCountryCode = code
            UserDefaults.standard.set(code, forKey: AppStorageKeys.radioRegionCountryCode)
        }
        if let name = effectiveCountryName {
            UserDefaults.standard.set(name, forKey: AppStorageKeys.radioRegionCountryName)
        }
        showRegionPicker = false
        Task { await loadDiscovery(force: true) }
    }

    /// Explicit country choice (cascade step a): persists, clears the old
    /// country's region choice and refills the picker list.
    private func chooseCountry(code: String, name: String) {
        chosenCountryCode = code
        chosenCountryName = name
        UserDefaults.standard.set(code, forKey: AppStorageKeys.radioChosenCountryCode)
        UserDefaults.standard.set(name, forKey: AppStorageKeys.radioChosenCountryName)
        // The old country's region makes no sense anymore.
        chosenState = nil
        impliedCountryCode = nil
        for key in [AppStorageKeys.radioRegionState, AppStorageKeys.radioRegionQueryNames,
                    AppStorageKeys.radioRegionCountryCode, AppStorageKeys.radioRegionCountryName] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        regional = []
        availableStates = []
        Task { await loadDiscovery(force: true) }
    }

    /// The row has its stations before the tiles exist — so the logos are
    /// resolved from HERE, not from whichever tile happens to stay visible
    /// long enough.
    private func warmLogos(_ stations: [RadioStation]) {
        let list = stations.map { (id: $0.id, name: $0.name, homepage: $0.homepage) }
        Task { await RadioLogoService.shared.warm(list) }
    }

    private func loadDiscovery(force: Bool = false) async {
        // 26b2c13: cold start ~10 s to ANY content — the last composed rows
        // land in frame 1 (before any network), the fresh composition then
        // replaces them calm-gated. Stale beats blank; the persisted day is
        // informational (a new day recomputes right after).
        if !force, popular.isEmpty, regional.isEmpty,
           let cached = RadioStore.cachedDiscovery() {
            popular = cached.popular
            regional = cached.regional
            RadioProvider.shared.remember(cached.popular + cached.regional)
            warmLogos(cached.popular + cached.regional)
        }
        guard networkMonitor.isConnected else { return }
        if !force, discoveryLoaded { return }
        #if DEBUG
        if UITestSeed.isActive {
            // Deterministic stand-in — no real Radio Browser call in the harness.
            popular = UITestSeed.seedRadioCatalog
            regional = UITestSeed.seedRadioCatalog
            // Seed region ONCE — after "Change region" the picker must win,
            // not an immediate re-choose by the seed branch. A PERSISTED
            // choice (UserDefaults survive across launches within a suite)
            // counts as applied, else the re-choose fires on the next run.
            if chosenState != nil { seedRegionApplied = true }
            if chosenState == nil, !seedRegionApplied {
                chosenState = "Seed Region"
                seedRegionApplied = true
            }
            availableStates = [
                RadioBrowseCuration.Curated(display: "Seed Region", queryNames: ["Seed Region"], stationCount: 3),
                RadioBrowseCuration.Curated(display: "Seed Region Two", queryNames: ["Seed Region Two"], stationCount: 2),
            ]   // picker testable
            discoveryLoaded = true
            return
        }
        #endif
        // National: country top-votes instead of world —
        // less foreign-language noise; search covers the exotics. b1ab99d:
        // the country follows the cascade (choice beats guess).
        discoveryFailed = false
        async let topTask = Self.nationalPopular(nationalEffectiveCode)
        async let regionTask = Self.stateStations(chosenState, countryCode: regionEffectiveCode)
        let (topResult, topFailed) = await topTask
        let regionResult = await regionTask
        // A throw is not an end: the failed run does NOT count as loaded, the
        // section says so with a way back in, and the next attempt is free.
        if topFailed, topResult.isEmpty, popular.isEmpty {
            discoveryFailed = true
            Logger.library.error("RADIO discovery failed — retry offered, not counted as loaded")
            return
        }
        RadioProvider.shared.remember(topResult + regionResult)   // resolvable for play
        warmLogos(topResult + regionResult)
        // The state list of the effective country (once per session) — a
        // country without states leaves the region section silently hidden.
        // Decoupled from chosenState (fixlet 4575a76): a returner with a
        // persisted state must still get the picker list when changing.
        // b942da6: raw entries run through the pure curation (merge/filter/sort).
        // The STATE list belongs to the region layer (its country decides
        // which states exist) — Q5b assignment.
        if availableStates.isEmpty, let countryName = effectiveCountryName {
            let raw = (try? await RadioBrowserClient.states(countryName: countryName)) ?? []
            // cd5cc4a (2): core countries (DE/CH/AT) show their CANONICAL
            // regions (aliases pooled, nationwide names dropped, unmapped
            // pooled into "Other"); everyone else keeps the generic curation.
            availableStates = RadioRegionCanon.curated(
                raw, countryCode: regionEffectiveCode,
                otherLabel: String(localized: "Other regions"))
                ?? RadioBrowseCuration.curated(raw)
        }
        // 26b2c13: persist the composed rows — the NEXT cold start shows
        // them in frame 1 (day rides along; a new day recomputes but shows
        // the stale state until the fresh one lands, never blank).
        RadioStore.saveDiscovery(popular: topResult, regional: regionResult,
                                 day: Self.rotationDay())
        // Layout-shift: the discovery sections land as whole-section inserts —
        // apply through the shared calm gate, never mid-scroll.
        BottomBarState.shared.runWhenCalm { [self] in
            popular = topResult
            regional = regionResult
        }
        discoveryLoaded = true
    }

    /// e4bd910 FINAL: socket + daily rotation — pool = votes + clicktrend
    /// (deduped, losers ride as detail variants), seats 1–3 = clicktrend top,
    /// rest day-seeded. Deterministic in the UI harness (fixed test day).
    private static func rotationDay() -> Int {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitest") { return 20_260_101 }
        #endif
        return RediscoverSections.daySeed(for: Date())
    }

    private static func nationalPopular(_ countryCode: String?) async -> (stations: [RadioStation], failed: Bool) {
        guard let countryCode else {
            // a4e747e: WITHOUT a country the list is the WORLD top-votes —
            // measured: US/FR/IR/RU/GB in the first 40, one German station.
            // That is the honest source of "a foreign stream in my list": not
            // the variant merge (the DE query returns 400 stations, ALL with
            // countrycode DE and German domains — measured), but this
            // fallback. It stays, because a list beats an empty tab; the
            // TITLE says "Popular Stations" instead of naming a country, and
            // the log names it so a report is decidable.
            do {
                let world = RadioMapping.dedupeForDisplay(try await RadioBrowserClient.popular())
                Logger.library.notice("RADIO popular: NO country code — showing WORLD top-votes (\(world.count) stations)")
                return (world, false)
            } catch {
                Logger.library.error("RADIO world popular FAILED: \(String(describing: error), privacy: .public)")
                return ([], true)
            }
        }
        // 19a8b4c: a country with a first-hand listener core resolves it
        // against a DEEP vote pool (the core's whole point is that ma-big
        // stations can rank LOW in votes — a shallow pool would miss them).
        let core = RadioListenerCores.national(countryCode: countryCode)
        let poolLimit = core == nil ? 30 : 300
        // The two sources stay best-effort against each other — FAILED means
        // both threw, an empty but successful answer stays an answer.
        async let votesList: [RadioStation]? = try? await RadioBrowserClient.byRegion(countryCode: countryCode, limit: poolLimit)
        async let trendList: [RadioStation]? = try? await RadioBrowserClient.byRegionClicktrend(countryCode: countryCode, limit: 30)
        let rawVotes = await votesList
        let rawTrend = await trendList
        if rawVotes == nil && rawTrend == nil {
            Logger.library.error("RADIO national popular FAILED for \(countryCode, privacy: .public)")
            return ([], true)
        }
        // a4e747e: the country context travels WITH the lists — a station
        // carrying a DIFFERENT country's code has no business being the
        // default in a country-filtered list, however good its bitrate.
        let votes = RadioMapping.dedupeForDisplay(
            RadioMapping.keepingCountry(countryCode, in: rawVotes ?? []))
        let trend = RadioMapping.dedupeForDisplay(
            RadioMapping.keepingCountry(countryCode, in: rawTrend ?? []))
        let seed = RadioRotation.seed(day: rotationDay(), countryCode: countryCode)
        guard let core else {
            return (RadioRotation.compose(
                votes: votes, clicktrend: trend, seed: seed, limit: 12), false)
        }
        let resolved = await resolveCore(core, pool: votes + trend, countryCode: countryCode)
        return (RadioRotation.composeWithCore(
            core: resolved, votes: votes, clicktrend: trend,
            seed: seed, limit: 12), false)
    }

    /// 19a8b4c: resolve a first-hand core against the fetched pool; names
    /// the pool does not carry get a BOUNDED number of targeted catalog
    /// lookups (the ladder's query forms, politely sequential, capped) —
    /// then the honest quote goes to the log, misses are never silent.
    private static func resolveCore(_ core: [String], pool: [RadioStation],
                                    countryCode: String) async -> [RadioStation] {
        var resolution = RadioCoreResolve.resolve(core: core, pool: pool, countryCode: countryCode)
        // Lookups only for misses within the row-relevant head of the core —
        // a rank-90 miss changes nothing visible and costs a request.
        let relevant = resolution.misses.filter { core.firstIndex(of: $0).map { $0 < 20 } ?? false }
        var lookedUp: [RadioStation] = []
        for missName in relevant.prefix(6) {
            for query in RadioCoreResolve.lookupQueries(missName, countryCode: countryCode).prefix(3) {
                guard let found = try? await RadioBrowserClient.search(name: query, limit: 10) else { continue }
                let candidates = RadioMapping.keepingCountry(countryCode, in: found)
                let probe = RadioCoreResolve.resolve(core: [missName], pool: candidates,
                                                     countryCode: countryCode)
                if !probe.stations.isEmpty {
                    lookedUp += candidates
                    break
                }
            }
        }
        if !lookedUp.isEmpty {
            resolution = RadioCoreResolve.resolve(core: core, pool: pool + lookedUp,
                                                  countryCode: countryCode)
        }
        RadioProvider.shared.remember(resolution.stations)
        let renames = resolution.mapping.map { "\($0.core)→\($0.matched)" }.joined(separator: " · ")
        Logger.library.notice("RADIO core \(countryCode, privacy: .public) resolved=\(resolution.stations.count)/\(core.count) misses=\(resolution.misses.joined(separator: " · "), privacy: .public) renames=\(renames, privacy: .public)")
        return resolution.stations
    }

    /// The REAL region: stations of the user-chosen state (never guessed,
    /// never located — same choose-once pattern as the drive-mode BT device).
    /// b942da6: the query runs against ALL merged name variants (persisted at
    /// choice time) — otherwise the other spelling's stations vanish; results
    /// dedupe by station id, first (best-voted of the winner name) stays.
    private static func stateStations(_ state: String?, countryCode: String?) async -> [RadioStation] {
        guard let state, !state.isEmpty else { return [] }
        let names = (UserDefaults.standard.array(forKey: AppStorageKeys.radioRegionQueryNames) as? [String])
            .flatMap { $0.isEmpty ? nil : $0 } ?? [state]
        // 71b277f (A): PARALLEL fan-out with a politeness cap of 4 — the
        // sequential 2×N roundtrips over all merged name variants took
        // seconds for NRW after the Sonstige stage widened the name list.
        var votesMerged: [RadioStation] = []
        var trendMerged: [RadioStation] = []
        await withTaskGroup(of: (Int, [RadioStation], [RadioStation]).self) { group in
            var active = 0
            var index = 0
            var results: [Int: ([RadioStation], [RadioStation])] = [:]
            func launch(_ i: Int) {
                let name = names[i]
                group.addTask {
                    async let v = (try? await RadioBrowserClient.byState(state: name)) ?? []
                    async let c = (try? await RadioBrowserClient.byStateClicktrend(state: name)) ?? []
                    return (i, await v, await c)
                }
            }
            while index < min(4, names.count) { launch(index); index += 1; active += 1 }
            while active > 0, let (i, v, c) = await group.next() {
                results[i] = (v, c)
                active -= 1
                if index < names.count { launch(index); index += 1; active += 1 }
            }
            for i in results.keys.sorted() {
                let (v, c) = results[i]!
                votesMerged.append(contentsOf: v)
                trendMerged.append(contentsOf: c)
                // Log-first (71b277f): one line per name variant.
                Logger.library.notice("RADIO regional name=\(names[i], privacy: .public) votes=\(v.count) trend=\(c.count)")
            }
        }
        // 71b277f (B/Kandidat 2): order by VOTES before dedupe — survival is
        // decided by vote mass, never by fetch order.
        let votesOrdered = votesMerged.sorted { ($0.votes ?? 0) > ($1.votes ?? 0) }
        var seen = Set<String>()
        let votesUnique = votesOrdered.filter { seen.insert($0.id).inserted }
        // 19a8b4c: the Bundesland core (ma Top Ten / Radiotest column). The
        // published lists carry NATIONWIDE stations too (Deutschlandfunk in
        // a Länder top ten), which the by-state pool may not tag — the
        // country vote pool joins the resolution pool for exactly those.
        var core: [RadioStation] = []
        if let coreNames = RadioListenerCores.regional(countryCode: countryCode, regionName: state) {
            let countryPool = (try? await RadioBrowserClient.byRegion(
                countryCode: countryCode ?? "", limit: 300)) ?? []
            core = await resolveCore(coreNames,
                                     pool: votesMerged + RadioMapping.keepingCountry(countryCode ?? "", in: countryPool),
                                     countryCode: countryCode ?? "")
        }
        // 71b277f (B, Screenshot-entschieden): regional socket sits on VOTES;
        // clicktrend joins the pool only above a minimum-votes floor.
        let composed = RadioRotation.composeWithCore(
            core: core,
            votes: RadioMapping.dedupeForDisplay(votesUnique),
            clicktrend: RadioMapping.dedupeForDisplay(trendMerged),
            seed: RadioRotation.seed(day: rotationDay(), countryCode: state),
            limit: 12, socket: .votes, minTrendVotes: 50)
        Logger.library.notice("RADIO regional composed pool=\(votesUnique.count)+\(trendMerged.count) out=\(composed.map { RadioMapping.displayName($0.name) }.joined(separator: " · "), privacy: .public)")
        return composed
    }
}
