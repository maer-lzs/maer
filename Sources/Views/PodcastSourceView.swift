import SwiftUI

/// Podcast-Abos verwalten (Einstellungen → Quellen): Feed-URL hinzufügen,
/// abonnierte Shows auflisten und entfernen. Quellenspezifische Verwaltung,
/// analog `LocalFilesView` — der Podcast-Tab konsumiert nur.
struct PodcastSourceView: View {
    @ObservedObject private var subs = PodcastSubscriptions.shared

    @State private var feedURL = ""
    @State private var isAdding = false
    @State private var errorText: String?

    var body: some View {
        List {
            Section {
                TextField("Feed URL", text: $feedURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.done)
                    .onSubmit { add() }
                Button {
                    add()
                } label: {
                    if isAdding {
                        HStack { ProgressView(); Text("Adding…").foregroundStyle(.secondary) }
                    } else {
                        Label("Add Feed", systemImage: "plus")
                    }
                }
                .disabled(isAdding || feedURL.trimmingCharacters(in: .whitespaces).isEmpty)
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("Paste the RSS feed URL of a podcast.")
            }

            if !subs.shows.isEmpty {
                Section("Subscriptions") {
                    ForEach(subs.shows) { show in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(show.title).lineLimit(1)
                            Text("\(show.episodes.count) episodes")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { subs.unsubscribe(id: subs.shows[index].id) }
                    }
                }
            }
        }
        .navigationTitle("Podcasts")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add() {
        let url = feedURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty, !isAdding else { return }
        isAdding = true
        errorText = nil
        Task {
            let ok = await subs.subscribe(urlString: url)
            isAdding = false
            if ok {
                feedURL = ""
            } else {
                errorText = String(localized: "Could not load this feed. Check the URL.")
            }
        }
    }
}
