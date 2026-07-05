import SwiftUI

/// Detailseite eines Buchs: Cover, Titel, Autor, Beschreibung und ein
/// Play-Button, der die Wiedergabe im Coordinator startet und zum vollen
/// Player navigiert. Wird beim Tippen auf ein Buch in der Bibliothek gezeigt.
struct BookDetailScreen: View {
    let entry: LibraryEntry
    @ObservedObject var coordinator: PlayerCoordinator

    @State private var detail: LibraryItemDetail?
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                BookCoverView(
                    url: coordinator.apiClient.coverURL(forItemId: entry.id),
                    progress: entry.progress,
                    size: 200
                )
                .padding(.top)

                VStack(spacing: 6) {
                    Text(entry.item.title)
                        .font(.title2).bold()
                        .multilineTextAlignment(.center)
                    if let author = entry.item.author {
                        Text(author)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let p = entry.progress, p.isStarted {
                        Text("\(p.percentInt) % gehört")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if entry.progress?.isFinished == true {
                        Text("Abgeschlossen")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)

                Button {
                    Task { await coordinator.open(item: entry.item) }
                } label: {
                    HStack {
                        if isThisBookLoading {
                            ProgressView()
                                .tint(.white)
                            Text("Wird gestartet…")
                        } else {
                            Image(systemName: "play.fill")
                            Text(playButtonLabel)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isThisBookLoading)
                .padding(.horizontal)

                if let description = detail?.media.metadata?.description, !description.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Beschreibung")
                            .font(.headline)
                        Text(description)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                } else if isLoading {
                    ProgressView().padding()
                }
            }
            .padding(.bottom, 40)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            isLoading = true
            detail = try? await coordinator.apiClient.fetchItemDetail(itemId: entry.id)
            isLoading = false
        }
    }

    private var playButtonLabel: String {
        if let p = entry.progress, p.isStarted { return "Weiter hören" }
        return "Abspielen"
    }

    /// True, während der Coordinator gerade genau dieses Buch lädt. So dreht
    /// sich der Spinner nur am richtigen Button, nicht wenn zufällig ein
    /// anderes Buch geladen wird.
    private var isThisBookLoading: Bool {
        coordinator.isLoading && coordinator.activeItem?.id == entry.id
    }
}
