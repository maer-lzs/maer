// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The suggestion-language MULTI-select. Device locale
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
            // Every service toggle carries a stable a11y id. Journeys
            // match ids, never labels (a label predicate once matched the tab
            // pill behind the sheet). One convention, no half-set.
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
                Text("Catalog rows, shelves and suggestions prefer these languages (several mix fairly). Collections that carry nothing in them stay reachable through their own pages. This does not change the app language, which follows your iOS system setting.")
            }
        }
        .navigationTitle(Text("Content Languages"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ code: String) {
        if selected.contains(code) {
            // Never empty. The last selection stays (locale default logic
            // would otherwise silently take over mid-flight).
            guard selected.count > 1 else { return }
            selected.remove(code)
        } else {
            selected.insert(code)
        }
        AppStorageKeys.set(Array(selected).sorted(), for: AppStorageKeys.suggestionLanguages)
        // Bite WITHOUT an app restart. Invalidate the two caches
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
