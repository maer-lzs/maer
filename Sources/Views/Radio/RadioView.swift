// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import OSLog

/// The radio tab. On top, the user's own stations (favorites + last-heard
/// rows). Below, the catalog browse layer: Popular, From your region, and
/// curated genres. All net-gated, so offline the tab falls back to the
/// cached favorites/recents and nothing breaks. Stations play directly
/// (play replaces the active playback, never queued).
struct RadioView: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    var isActive: Bool = true
    @Environment(\.isOnline) private var isOnline
    @Environment(\.pushRadioRoute) private var pushRadioRoute

    // User's own stations (UserDefaults-backed store).
    @State private var favorites: [RadioStation] = []
    @State private var recents: [RadioStation] = []
    // Teil 3: stations ranked by play frequency (net-independent. From the store).
    @State private var mostPlayed: [RadioStation] = []
    /// The merged first row, and its full stock for the counting head.
    @State private var myStations: [RadioStation] = []
    @State private var myStationsTotal = 0
    /// Measured seconds per station. The card line's second state.
    @State private var radioSeconds: [String: Int] = [:]
    // Catalog browse. Cached per session, re-fetched only on refresh.
    @State private var popular: [RadioStation] = []
    @State private var copiedLogoReport = false
    @State private var regional: [RadioStation] = []
    @State private var discoveryLoaded = false
    /// Fourth instance of the throw-is-not-the-end class, mild form: the
    /// fetches swallowed their errors and `discoveryLoaded` was set
    /// unconditionally. A failed first run counted as "loaded", and the
    /// empty text advised searching a catalog that had simply not arrived.
    @State private var discoveryFailed = false
    private let localeCode = RadioCatalog.deviceRegionCode()
    /// The browse-layer choices live in the ONE observed source. Private
    /// `@State` copies were two truths, and an adopted foreign
    /// choice would never have reached a mounted page.
    @ObservedObject private var browseSelection = RadioBrowseSelection.shared
    private var chosenState: String? { browseSelection.chosenState }
    private var chosenCountryCode: String? { browseSelection.chosenCountryCode }
    private var chosenCountryName: String? { browseSelection.chosenCountryName }
    private var impliedCountryCode: String? { browseSelection.impliedCountryCode }
    /// Curated picker list: merged variants, noise filtered,
    /// sorted by station count.
    @State private var availableStates: [RadioBrowseCuration.Curated] = []
    @State private var showRegionPicker = false
    @State private var showCountryPicker = false
    /// The NATIONAL row's own country. Independent of the region.
    @State private var nationalCountryCode: String? = AppStorageKeys.string(AppStorageKeys.radioNationalCountryCode)
    @State private var nationalCountryName: String? = AppStorageKeys.string(AppStorageKeys.radioNationalCountryName)
    /// Which row a country choice applies to (the picker serves both).
    @State private var countryPickerTarget: CountryPickerTarget = .national

    enum CountryPickerTarget { case national, region }
    #if DEBUG
    @State private var seedRegionApplied = false
    #endif

    /// USER CHOICE BEATS GUESSING: the ONE country code feeding
    /// "Popular in …" and the region list.
    private var effectiveCountryCode: String? {
        RadioCountryCascade.effectiveCode(explicit: chosenCountryCode,
                                          regionImplied: impliedCountryCode,
                                          locale: localeCode)
    }

    /// The NATIONAL row's country. Own choice first; without one the
    /// shared cascade. That IS the migration: whoever never decouples sees
    /// exactly today's behaviour, without a jump on first launch.
    private var nationalEffectiveCode: String? {
        RadioCountryCascade.nationalCode(explicitNational: nationalCountryCode,
                                         shared: effectiveCountryCode)
    }

    /// The REGION row's country (its own cascade step, unchanged): the
    /// country implied by the chosen region, else the shared cascade.
    /// Every consumer of the shared cascade is assigned to a layer:
    /// everything below reads one of the two named
    /// properties. `effectiveCountryCode` itself is the shared FALLBACK and
    /// is not read directly by any surface any more.
    private var regionEffectiveCode: String? { effectiveCountryCode }

    /// English country name for the Radio Browser states path.
    private var effectiveCountryName: String? {
        if let chosenCountryName, !chosenCountryName.isEmpty { return chosenCountryName }
        if let implied = AppStorageKeys.string(AppStorageKeys.radioRegionCountryName),
           !implied.isEmpty { return implied }
        guard let code = effectiveCountryCode else { return nil }
        return Locale(identifier: "en_US").localizedString(forRegionCode: code)
    }

    /// "Popular in Switzerland". Follows the NATIONAL row's country, the same
    /// one the row's CONTENT follows; reading the shared cascade here put
    /// Germany over Swiss stations.
    private var nationalTitle: String {
        guard let code = nationalEffectiveCode,
              let name = Locale.current.localizedString(forRegionCode: code) else {
            return String(localized: "Popular Stations")
        }
        return String(localized: "Popular in \(name)")
    }

    /// The catalog ROW switch: the browse layer (popular, region, genres)
    /// hangs on it as one surface. Saved stations, recents and own streams
    /// are the user's holdings and never ask it.
    @AppStorage(AppStorageKeys.rowRadioCatalogVisible) private var catalogRowVisible = true
    private var showsPopular: Bool { catalogRowVisible && RadioCatalog.showsPopular(isConnected: isOnline, popular: popular) }
    private var showsRegion: Bool { catalogRowVisible && RadioCatalog.showsRegion(isConnected: isOnline, regionCode: regionEffectiveCode, regional: regional) }
    private var showsGenres: Bool { catalogRowVisible && RadioCatalog.showsGenres(isConnected: isOnline) }
    private var hasAnyContent: Bool {
        !myStations.isEmpty || !recents.isEmpty || showsPopular || showsRegion || showsGenres
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                // "My Stations" (favorites + most played) is the
                // first row and a CARD; "Recently Played" sits right below it
                // as a small tile.
                //
                // The reason they stay apart is the user': recently played is a
                // STATE, my stations is a PREFERENCE. Two truths do not
                // belong in one row. And because the last-heard station is
                // usually also the most-heard one, the upper row leaves it
                // out: it is not gone, it stands one row lower. Behind the
                // chevron it reappears. There is no neighbouring row there.
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
                    // Recently played sits right under My Stations: what
                    // you heard comes before the offer from outside (the
                    // order of the tabs). The whole recent list as the
                    // plain tile row, small, no show line (stale for a
                    // station that stopped). The exclusion rule holds:
                    // "My Stations" leaves out the station this row shows.
                    cardRow(title: String(localized: "Recently Played"), stations: recents)
                }
                if showsPopular {
                    VStack(alignment: .leading, spacing: 4) {
                        VStack(alignment: .leading, spacing: 8) {
                            // The browse rows carry the counting
                            // heading and a full page. Every row is a
                            // preview, and this preview has a page behind it.
                            RowHeading<RadioRoute>(
                                title: "", verbatimTitle: nationalTitle,
                                total: popular.count,
                                destination: .stationList(title: nationalTitle, stations: popular))
                            browseCardScroller(stations: popular)
                        }
                        // The country switch follows the REGION pattern
                        // exactly. A "Change
                        // country" link under the section (no ▾ on the
                        // title), same style/position as "Change region";
                        // ONE mechanism (the existing cascade) behind both.
                        Button {
                            // This link sits under the NATIONAL row and
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
                if catalogRowVisible { regionSection }
                if showsGenres {
                    genreSection
                }
                #if DEBUG
                // A diagnosis for development builds, not a control for
                // the person.
                logoDiagnosisSection
                #endif
                if !hasAnyContent {
                    if discoveryFailed {
                        // A failed load is not "no stations". The old advice
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
                    } else if isOnline && !discoveryLoaded {
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
        // Choice-family adoption: foreign favorites refill "My Stations",
        // foreign browse choices re-query the affected rows in place.
        .onReceive(NotificationCenter.default.publisher(for: .userChoicesAdopted)) { note in
            guard let keys = note.userInfo?["keys"] as? [String] else { return }
            if keys.contains("radioFavorites") { reload() }
            let browseKeys = [AppStorageKeys.radioRegionState,
                              AppStorageKeys.radioChosenCountryCode,
                              AppStorageKeys.radioRegionCountryCode]
            if keys.contains(where: { browseKeys.contains($0) }) {
                regional = []
                availableStates = []
                Task { await loadDiscovery(force: true) }
            }
        }
        // Region picker as a sheet (search field + country layer).
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
            .followsAppearanceChoice()
        }
        .sheet(isPresented: $showRegionPicker) {
            RadioRegionPickerSheet(states: availableStates,
                                   countryTitle: regionCountryDisplayName,
                                   onChooseRegion: chooseRegion,
                                   onChooseCountry: chooseCountry)
                .followsAppearanceChoice()
        }
    }

    /// The REGION row's country name, for its own picker layer.
    private var regionCountryDisplayName: String? {
        regionEffectiveCode.flatMap { Locale.current.localizedString(forRegionCode: $0) }
    }

    // MARK: - Sections

    /// The row itself is the shared `RadioCardRow` (also on Home).
    private func cardRow(title: String, stations: [RadioStation]) -> some View {
        RadioCardRow(title: title, stations: stations,
                     playerCoordinator: playerCoordinator,
                     onFavoriteToggled: reload)
    }

    /// The card strip WITHOUT its own title. The counted RowHeading above
    /// carries title and page entry.
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

    #if DEBUG
    /// The cover report is only reproducible on a device, and reading the
    /// device log needs a Mac, a cable and root. This makes the same answer
    /// copyable from the phone itself. It reads the STORED state and never
    /// re-runs the chain, because a diagnosis that changes what it measures is
    /// worthless. Diagnostic UI stays verbatim (project convention).
    @ViewBuilder
    private var logoDiagnosisSection: some View {
        if !popular.isEmpty || !regional.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    Task {
                        // Every station this session has SEEN, not just the two
                        // rows on this screen: the genre pages are exactly where
                        // stations appear that were never played, and those are
                        // the ones the question is about. Measuring the wrong set
                        // is how a diagnosis reports a confident zero.
                        let shown = RadioProvider.shared.sessionStations.values
                            .map { (id: $0.id, name: $0.name, faviconURL: $0.faviconURL) }
                        // The session state separates the three causes
                        // behind "no result". Asked from the actor, hence the
                        // wrapping Task; everything else stays on main.
                        let session = await RadioLogoService.shared.sessionState()
                        let base = RadioLogoReport.text(
                            RadioLogoReport.rows(stations: shown,
                                                 chainResults: RadioLogoService.storedOutcomes(),
                                                 now: Date().timeIntervalSince1970,
                                                 waiting: session.waiting,
                                                 sessionFailed: session.failed,
                                                 gaveUp: session.gaveUp))
                        // The missing listening time needs a
                        // MEASUREMENT, not a guess. The report answers two
                        // questions per card: does the store hold >= 3600 s for
                        // this id, and what does the card's line rule decide?
                        let seconds = ListeningStatsStore.shared.radioSeconds()
                        var hoursBlock = "\n\nMEINE SENDER (Hoerzeit-Verdrahtung):\n"
                        for station in myStations.prefix(8) {
                            let s = seconds[station.id] ?? 0
                            let line = RadioMyStations.cardLine(isRunning: false,
                                                                runningLine: nil, seconds: s)
                            let verdict: String
                            switch line {
                            case .listened(let hours): verdict = "zeigt \(hours) Std."
                            case .none: verdict = "zeigt nichts (unter der Stunde)"
                            case .running: verdict = "-"
                            }
                            // Shorten to the FIRST characters after the
                            // radio:rb: prefix.
                            // The UUID tail is the import batch's shared node
                            // field, six different stations can end identically.
                            hoursBlock += "  \(station.name.prefix(28)): id=\(RadioLogoReport.shortID(station.id)) sek=\(s) → \(verdict)\n"
                        }
                        hoursBlock += "  Topf gesamt: \(seconds.count) Sender mit Sekunden, "
                            + "Summe \(seconds.values.reduce(0, +)) s\n"
                        // The POT itself, top entries with FULL keys and
                        // resolved names. The question is what six stations
                        // booked onto one id, and only the pot can answer which
                        // id carries whose seconds.
                        // The sync witness. Does anything from the
                        // OTHER devices arrive here at all, and is the one
                        // switch above every carrier even open? It is not
                        // the iCloud switch, whatever its key is called:
                        // with a service set up no Apple carrier is built.
                        hoursBlock += "  Sync: Schalter \(AppStorageKeys.syncAcrossDevicesEnabled ? "AN" : "AUS")"
                        let pots = ListeningStatsStore.shared.foreignPotOverview()
                        hoursBlock += " · fremde Toepfe: \(pots.count)\n"
                        for pot in pots {
                            hoursBlock += "    \(pot.device.prefix(10))…: Tage \(pot.daySeconds) s · Radio \(pot.radioSeconds) s\n"
                        }
                        hoursBlock += "  Topf-Draufsicht (Top 10):\n"
                        for (potId, potSeconds) in seconds.sorted(by: { $0.value > $1.value }).prefix(10) {
                            let resolved = RadioStore.station(forId: potId)?.name
                                ?? RadioProvider.shared.sessionStations[potId]?.name
                                ?? "⟨unaufloesbar⟩"
                            hoursBlock += "    \(RadioLogoReport.shortID(potId)) = \(potSeconds) s → \(resolved.prefix(26))\n"
                        }
                        // Only one of several favorites showed. The
                        // diagnosis answers WHICH favorites the store knows, which
                        // the row shows, and why one is missing (exclusion), so
                        // the user's device settles source vs. cap vs. ranking.
                        let storeFavs = RadioStore.favorites()
                        let shownIds = Set(myStations.map(\.id))
                        let excluded = RadioMyStations.excludedID(recents: RadioStore.recents())
                        hoursBlock += "\nFAVORITEN (Speisung):\n"
                        hoursBlock += "  Store kennt \(storeFavs.count): "
                            + storeFavs.map { $0.name.prefix(20) }.joined(separator: " · ") + "\n"
                        for favorite in storeFavs {
                            let why: String
                            if shownIds.contains(favorite.id) { why = "in der Reihe" }
                            else if favorite.id == excluded { why = "ausgelassen (steht in Zuletzt gespielt)" }
                            else { why = "FEHLT: weder Reihe noch Auslass-Regel" }
                            hoursBlock += "  \(favorite.name.prefix(24)): \(why)\n"
                        }
                        UIPasteboard.general.string = base + hoursBlock
                        copiedLogoReport = true
                        // The display half needs to LOAD, so it lands a moment
                        // later. The summary above is already in the clipboard,
                        // and this replaces it once the pictures answered.
                        Task {
                            let urls = RadioLogoService.storedURLs()
                            let names = Dictionary(shown.map { ($0.id, $0.name) },
                                                   uniquingKeysWith: { a, _ in a })
                            var loaded: [RadioLogoReport.Loaded] = []
                            for (id, url) in urls.sorted(by: { $0.key < $1.key })
                            where names[id] != nil {
                                if loaded.count >= 12 { break }
                                let image = await Artwork.thumbnail(for: url)
                                let width = Int((image?.size.width ?? 0) * (image?.scale ?? 1))
                                let height = Int((image?.size.height ?? 0) * (image?.scale ?? 1))
                                let verdict: String
                                if image == nil {
                                    // The WHY per line. One probe
                                    // request classifies (diagnosis only,
                                    // books nothing).
                                    var status: Int?
                                    var urlError: Int?
                                    do {
                                        let (_, http) = try await HTTP.data(from: url, lane: .stream)
                                        status = http?.statusCode
                                    } catch {
                                        urlError = (error as? URLError)?.code.rawValue
                                    }
                                    verdict = RadioLogoReport.failureLabel(statusCode: status,
                                                                           urlErrorCode: urlError)
                                }
                                else if !RadioFaviconGate.acceptableTouchIcon(pixelWidth: width,
                                                                              pixelHeight: height) {
                                    verdict = "verworfen"
                                } else { verdict = "angezeigt" }
                                loaded.append(RadioLogoReport.Loaded(
                                    name: names[id] ?? id, url: url.absoluteString,
                                    pixels: image == nil ? "ohne Bild" : "\(width)x\(height)",
                                    verdict: verdict))
                            }
                            UIPasteboard.general.string = base + hoursBlock + RadioLogoReport.loadedText(loaded)
                        }
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
    #endif

    private var genreSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            RowHeading.plain("By Genre")
            CategoryDeckGrid(entries: RadioCatalog.genres.map { genre in
                CategoryDeckEntry(id: genre.tag, title: genre.title, systemImage: genre.systemImage,
                                  count: nil, accessibilityId: "radio-genre-\(genre.tag)") {
                    pushRadioRoute(.genre(tag: genre.tag, title: genre.title))
                }
            })
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No stations yet", systemImage: "dot.radiowaves.left.and.right")
        } description: {
            Text("Search the catalog with the magnifier and star your stations, or add a stream URL under Settings → Areas → Radio.")
        }
        .padding(.top, 60)
    }

    // MARK: - Loading

    private func reload() {
        let favs = RadioStore.favorites()
        // NO longer filtered against the favorites. Row 2 shows the
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
        // Layout-shift: same calm gate as loadDiscovery. The per-section
        // empty→filled rule applies to the library rows too (user-driven calls
        // run while calm, so they still apply instantly).
        ScrollCalm.run { [self] in
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
            // The section NEVER vanishes while loading. Right
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
                        browseSelection.clearRegion()
                        regional = []
                        // Refill the picker list immediately. Without this the
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
        } else if !availableStates.isEmpty, isOnline {
            VStack(alignment: .leading, spacing: 8) {
                RowHeading.plain("From Your Region")
                // The picker is a SHEET now. A Menu cannot carry the
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
    /// The NATIONAL choice. Writes only its own keys, the region row
    /// stays untouched (that is the whole point of the decoupling).
    private func chooseNationalCountry(code: String, name: String) {
        nationalCountryCode = code
        nationalCountryName = name
        AppStorageKeys.set(code, for: AppStorageKeys.radioNationalCountryCode)
        AppStorageKeys.set(name, for: AppStorageKeys.radioNationalCountryName)
        Task { await loadDiscovery(force: true) }
    }

    private func chooseRegion(_ entry: RadioBrowseCuration.Curated) {
        browseSelection.chooseRegion(display: entry.display, queryNames: entry.queryNames,
                                     impliedCode: regionEffectiveCode,
                                     impliedName: effectiveCountryName)
        showRegionPicker = false
        Task { await loadDiscovery(force: true) }
    }

    /// Explicit country choice (cascade step a): persists, clears the old
    /// country's region choice and refills the picker list.
    private func chooseCountry(code: String, name: String) {
        browseSelection.chooseCountry(code: code, name: name)
        regional = []
        availableStates = []
        Task { await loadDiscovery(force: true) }
    }

    /// The row has its stations before the tiles exist. So the logos are
    /// resolved from HERE, not from whichever tile happens to stay visible
    /// long enough.
    private func warmLogos(_ stations: [RadioStation]) {
        let list = stations.map { (id: $0.id, name: $0.name, homepage: $0.homepage) }
        Task { await RadioLogoService.shared.warm(list) }
    }

    private func loadDiscovery(force: Bool = false) async {
        // A hidden catalog row loads nothing: the switch would otherwise
        // hide the surface while its traffic kept running.
        guard catalogRowVisible else { return }
        // Source off: the client would cancel every request anyway; booking
        // the pass as loaded here keeps the surface at its honest empty
        // state instead of an eternal spinner.
        guard AppStorageKeys.radioActive else { discoveryLoaded = true; return }
        // Cold start ~10 s to ANY content. The last composed rows
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
        guard isOnline else { return }
        if !force, discoveryLoaded { return }
        #if DEBUG
        if UITestSeed.isActive {
            // Deterministic stand-in. No real Radio Browser call in the harness.
            popular = UITestSeed.seedRadioCatalog
            regional = UITestSeed.seedRadioCatalog
            // Seed region ONCE. After "Change region" the picker must win,
            // not an immediate re-choose by the seed branch. A PERSISTED
            // choice (UserDefaults survive across launches within a suite)
            // counts as applied, else the re-choose fires on the next run.
            if chosenState != nil { seedRegionApplied = true }
            if chosenState == nil, !seedRegionApplied {
                browseSelection.seedRegion("Seed Region")
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
        // National: country top-votes instead of world.
        // Less foreign-language noise; search covers the exotics. The
        // country follows the cascade (choice beats guess).
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
        // The state list of the effective country (once per session). A
        // country without states leaves the region section silently hidden.
        // Decoupled from chosenState: a returner with a
        // persisted state must still get the picker list when changing.
        // Raw entries run through the pure curation (merge/filter/sort).
        // The STATE list belongs to the region layer. Its country decides
        // which states exist.
        if availableStates.isEmpty, let countryName = effectiveCountryName {
            let raw = (try? await RadioBrowserClient.states(countryName: countryName)) ?? []
            // Core countries (DE/CH/AT) show their CANONICAL
            // regions (aliases pooled, nationwide names dropped, unmapped
            // pooled into "Other"); everyone else keeps the generic curation.
            availableStates = RadioRegionCanon.curated(
                raw, countryCode: regionEffectiveCode,
                otherLabel: String(localized: "Other regions"))
                ?? RadioBrowseCuration.curated(raw)
        }
        // Persist the composed rows. The NEXT cold start shows
        // them in frame 1 (day rides along; a new day recomputes but shows
        // the stale state until the fresh one lands, never blank).
        RadioStore.saveDiscovery(popular: topResult, regional: regionResult,
                                 day: Self.rotationDay())
        // Layout-shift: the discovery sections land as whole-section inserts.
        // Apply through the shared calm gate, never mid-scroll.
        ScrollCalm.run { [self] in
            popular = topResult
            regional = regionResult
        }
        discoveryLoaded = true
    }

    /// Socket + daily rotation. Pool = votes + clicktrend
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
            // WITHOUT a country the list is the WORLD top-votes.
            // Measured: US/FR/IR/RU/GB in the first 40, one German station.
            // That is the honest source of "a foreign stream in my list": not
            // the variant merge (the DE query returns 400 stations, ALL with
            // countrycode DE and German domains. Measured), but this
            // fallback. It stays, because a list beats an empty tab; the
            // TITLE says "Popular Stations" instead of naming a country, and
            // the log names it so a report is decidable.
            do {
                let world = RadioMapping.dedupeForDisplay(try await RadioBrowserClient.popular())
                Logger.library.notice("RADIO popular: NO country code — showing WORLD top-votes (\(world.count) stations)")
                return (world, false)
            } catch {
                // A cancelled run is not a failure (shared rule). The empty
                // answer without the failed flag keeps the section quiet
                // instead of booking a phantom error.
                guard !error.isCancellation else { return ([], false) }
                Logger.library.error("RADIO world popular FAILED: \(String(describing: error), privacy: .public)")
                return ([], true)
            }
        }
        // A country with a first-hand listener core resolves it
        // against a DEEP vote pool (the core's whole point is that ma-big
        // stations can rank LOW in votes. A shallow pool would miss them).
        let core = RadioListenerCores.national(countryCode: countryCode)
        let poolLimit = core == nil ? 30 : 300
        // The two sources stay best-effort against each other. FAILED means
        // both threw, an empty but successful answer stays an answer.
        async let votesList: [RadioStation]? = try? await RadioBrowserClient.byRegion(countryCode: countryCode, limit: poolLimit)
        async let trendList: [RadioStation]? = try? await RadioBrowserClient.byRegionClicktrend(countryCode: countryCode, limit: 30)
        let rawVotes = await votesList
        let rawTrend = await trendList
        if rawVotes == nil && rawTrend == nil {
            Logger.library.error("RADIO national popular FAILED for \(countryCode, privacy: .public)")
            return ([], true)
        }
        // The country context travels WITH the lists. A station
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

    /// Resolve a first-hand core against the fetched pool; names
    /// the pool does not carry get a BOUNDED number of targeted catalog
    /// lookups (the ladder's query forms, politely sequential, capped).
    /// Then the honest quote goes to the log, misses are never silent.
    private static func resolveCore(_ core: [String], pool: [RadioStation],
                                    countryCode: String) async -> [RadioStation] {
        var resolution = RadioCoreResolve.resolve(core: core, pool: pool, countryCode: countryCode)
        // Lookups only for misses within the row-relevant head of the core.
        // A rank-90 miss changes nothing visible and costs a request.
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
    /// never located. Same choose-once pattern as the drive-mode BT device).
    /// The query runs against ALL merged name variants (persisted at
    /// choice time). Otherwise the other spelling's stations vanish; results
    /// dedupe by station id, first (best-voted of the winner name) stays.
    private static func stateStations(_ state: String?, countryCode: String?) async -> [RadioStation] {
        guard let state, !state.isEmpty else { return [] }
        let names = AppStorageKeys.stringArray(AppStorageKeys.radioRegionQueryNames)
            .flatMap { $0.isEmpty ? nil : $0 } ?? [state]
        // PARALLEL fan-out with a politeness cap of 4. The
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
                // Log-first: one line per name variant.
                Logger.library.notice("RADIO regional name=\(names[i], privacy: .public) votes=\(v.count) trend=\(c.count)")
            }
        }
        // Order by VOTES before dedupe. Survival is
        // decided by vote mass, never by fetch order.
        let votesOrdered = votesMerged.sorted { ($0.votes ?? 0) > ($1.votes ?? 0) }
        var seen = Set<String>()
        let votesUnique = votesOrdered.filter { seen.insert($0.id).inserted }
        // The Bundesland core (ma Top Ten / Radiotest column). The
        // published lists carry NATIONWIDE stations too (Deutschlandfunk in
        // a Länder top ten), which the by-state pool may not tag. The
        // country vote pool joins the resolution pool for exactly those.
        var core: [RadioStation] = []
        if let coreNames = RadioListenerCores.regional(countryCode: countryCode, regionName: state) {
            let countryPool = (try? await RadioBrowserClient.byRegion(
                countryCode: countryCode ?? "", limit: 300)) ?? []
            core = await resolveCore(coreNames,
                                     pool: votesMerged + RadioMapping.keepingCountry(countryCode ?? "", in: countryPool),
                                     countryCode: countryCode ?? "")
        }
        // The regional socket sits on VOTES;
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
