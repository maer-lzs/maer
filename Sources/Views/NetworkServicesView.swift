// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// a449534 (4): "Network Services & Privacy" — EVERY external service on one
/// page: a purpose sentence per row plus the REAL opt-out switch, bound to
/// the SAME AppStorage keys as the feature homes (second access point, one
/// truth — Regel 2). Head rule: servers first, overlays only fill gaps, no
/// accounts anywhere.
struct NetworkServicesView: View {
    @AppStorage(AppStorageKeys.musicArtistImagesOnline) private var artistImagesOnline = true
    @AppStorage(AppStorageKeys.musicHighResCovers) private var highResCovers = true
    @AppStorage(AppStorageKeys.musicLyricsOnlineLookup) private var lyricsOnline = true
    @AppStorage(AppStorageKeys.homeRecommendations) private var homeRecommendations = true
    @AppStorage(AppStorageKeys.radioEnabled) private var radioEnabled = false
    @AppStorage(AppStorageKeys.radioLogoChainEnabled) private var radioLogoChain = true
    @AppStorage(AppStorageKeys.librivoxRowsEnabled) private var librivoxRows = true
    @AppStorage(AppStorageKeys.archivePopularEnabled) private var archivePopular = true
    @AppStorage(AppStorageKeys.jamendoRowEnabled) private var jamendoRow = true
    @AppStorage(AppStorageKeys.jamendoClientId) private var jamendoClientId = ""

    var body: some View {
        Form {
            // #85 (f9ba23b S4): every service toggle carries a stable a11y id
            // — journeys match ids, never labels (the label predicate found
            // the tab pill behind the sheet once, 8b4327c). One convention,
            // no half-set.
            Section {
                Toggle(isOn: $artistImagesOnline) {
                    // bdfe8dc/22cf822: name the boundary AND its second half.
                    // Switching this off stops OUR web chain; portraits the
                    // server delivers keep showing — and the server may fetch
                    // those from external services itself (measured: 98 of
                    // 1521 artists, 92 via Last.fm). Saying only the first
                    // half would suggest no external service is involved.
                    serviceLabel(NetworkServiceNames.artistImages,
                                 purpose: "Artist portraits and identities for your music library. Portraits from your own server stay visible — your server may fetch them from external services itself; you control that there.")
                }
                .accessibilityIdentifier("network-artist-images-toggle")
                Toggle(isOn: $highResCovers) {
                    serviceLabel(NetworkServiceNames.hiResCovers,
                                 purpose: "High-resolution album covers for albums with a MusicBrainz ID.")
                }
                .accessibilityIdentifier("network-hires-covers-toggle")
                Toggle(isOn: $lyricsOnline) {
                    serviceLabel(NetworkServiceNames.lyrics,
                                 // 22cf822 parity: same half-truth applies —
                                 // the server can carry lyrics from its own
                                 // agents; our opt-out only gates OUR lookup.
                                 purpose: "Open lyrics lookup when your server has none — lyrics your server already carries stay, wherever it got them.")
                }
                .accessibilityIdentifier("network-lrclib-toggle")
                Toggle(isOn: $homeRecommendations) {
                    serviceLabel(NetworkServiceNames.appleCatalog,
                                 purpose: "Discover and Rediscover suggestions; searching the catalog and genre charts stays on demand.")
                }
                .accessibilityIdentifier("network-itunes-toggle")
                Toggle(isOn: $radioEnabled) {
                    serviceLabel(NetworkServiceNames.radioBrowser,
                                 purpose: "The community station catalog behind the Radio tab.")
                }
                .accessibilityIdentifier("network-radiobrowser-toggle")
                // e4bd910: the agreed logo fallback chain — ONE switch for
                // both stages (Wikidata P154 first, then the homepage
                // touch icon); off = placeholder right after the favicon.
                Toggle(isOn: $radioLogoChain) {
                    serviceLabel(NetworkServiceNames.radioLogoChain,
                                 purpose: "Logos for stations without a usable favicon.")
                }
                .accessibilityIdentifier("network-radio-logo-toggle")
                Toggle(isOn: $librivoxRows) {
                    serviceLabel(NetworkServiceNames.librivox,
                                 purpose: "Public-domain audiobooks for the free Discover rows.")
                }
                .accessibilityIdentifier("network-librivox-toggle")
                Toggle(isOn: $archivePopular) {
                    serviceLabel(NetworkServiceNames.internetArchive,
                                 purpose: "Popularity ranking and streams for the free audiobooks and the Free Classical area.")
                }
                .accessibilityIdentifier("network-archive-toggle")
                Toggle(isOn: $jamendoRow) {
                    serviceLabel(NetworkServiceNames.jamendo,
                                 purpose: "Creative-Commons music charts. Requires a client key; free API for non-commercial use.")
                }
                .accessibilityIdentifier("network-jamendo-toggle")
                if jamendoRow {
                    TextField("Own Jamendo client_id (optional)", text: $jamendoClientId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.caption)
                }
            } footer: {
                Text("Your servers come first — these services only fill gaps. None of them requires an account; requests carry no identifiers beyond the query itself. PodcastIndex is used only when you configured your own key on the podcast source page.")
            }
        }
        .navigationTitle(Text("Network Services & Privacy"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func serviceLabel(_ name: String, purpose: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: name)
            Text(purpose).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// f79c40c/2ee3c32: the suggestion-language MULTI-select — device locale
/// preselected; the choice drives catalog/recommendation requests, NOT the
/// app language (that stays the iOS system setting).
struct SuggestionLanguagesView: View {
    @State private var selected: Set<String> = Set(SuggestionLanguages.current())

    private var choices: [String] {
        var list = SuggestionLanguages.choosable
        // The device language is always choosable, even when exotic.
        for code in selected where !list.contains(code) { list.append(code) }
        return list
    }

    var body: some View {
        Form {
            // #85 (f9ba23b S4): every service toggle carries a stable a11y id
            // — journeys match ids, never labels (the label predicate found
            // the tab pill behind the sheet once, 8b4327c). One convention,
            // no half-set.
            Section {
                ForEach(choices, id: \.self) { code in
                    Button {
                        toggle(code)
                    } label: {
                        HStack {
                            Text(Locale.current.localizedString(forLanguageCode: code) ?? code)
                                .foregroundStyle(.primary)
                            Spacer()
                            if selected.contains(code) {
                                Image(systemName: "checkmark").foregroundStyle(AppTheme.accent)
                            }
                        }
                    }
                    .accessibilityIdentifier("suggestion-lang-\(code)")
                }
            } footer: {
                Text("Suggestions and catalog results prefer these languages (several mix fairly). This does not change the app language — that follows your iOS system setting.")
            }
        }
        .navigationTitle(Text("Suggestion Languages"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ code: String) {
        if selected.contains(code) {
            // Never empty — the last selection stays (locale default logic
            // would otherwise silently take over mid-flight).
            guard selected.count > 1 else { return }
            selected.remove(code)
        } else {
            selected.insert(code)
        }
        UserDefaults.standard.set(Array(selected).sorted(), forKey: AppStorageKeys.suggestionLanguages)
        // 784aceb: bite WITHOUT an app restart — invalidate the two caches
        // that hold language-shaped results and recompute right away (the
        // stores apply calm-gated; genre chips and catalog searches read the
        // key live and need no reset).
        PodcastRecommendationsStore.shared.invalidateForLanguageChange()
        FreeCatalogStore.shared.invalidateForLanguageChange()
        Task {
            await PodcastRecommendationsStore.shared.refreshIfNeeded()
            await FreeCatalogStore.shared.ensureLoaded()
        }
    }
}
