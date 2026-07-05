import SwiftUI

/// Detailseite eines Buchs: Cover, Titel, Autor, Beschreibung und ein
/// Play-Button, der die Wiedergabe im Coordinator startet und zum vollen
/// Player navigiert. Wird beim Tippen auf ein Buch in der Bibliothek gezeigt.
struct BookDetailScreen: View {
    let entry: LibraryEntry
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject var libraryViewModel: LibraryViewModel
    @ObservedObject private var downloadManager = DownloadManager.shared

    @State private var detail: LibraryItemDetail?
    @State private var isLoading = true
    @State private var showWiFiWarning = false
    @State private var isFinishedOverride: Bool?
    @State private var errorMessage: String?

    private var buttonShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                BookCoverView(
                    url: coordinator.apiClient.coverURL(forItemId: entry.id),
                    progress: entry.progress,
                    itemId: entry.id,
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
                    } else if isFinished {
                        Text("Abgeschlossen")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)

                infoSection

                playButton

                downloadSection

                markAsFinishedButton

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

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
        .alert("Kein WLAN erkannt", isPresented: $showWiFiWarning) {
            Button("Trotzdem laden") {
                Task { await reallyStartDownload() }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Du bist aktuell nicht im WLAN. Der Download könnte dein Mobilfunk-Datenvolumen verbrauchen.")
        }
        .task {
            isLoading = true
            detail = try? await coordinator.apiClient.fetchItemDetail(itemId: entry.id)
            isLoading = false
        }
    }

    // MARK: - Play/Pause

    /// Ist DIESES Buch gerade die aktive Session, wird eine eigene, echt
    /// beobachtende Unteransicht genutzt (siehe `ActivePlayButton`) — sonst
    /// reagiert der Button nicht zuverlässig auf Play/Pause-Wechsel, aus
    /// demselben Grund wie beim Mini-Player: `coordinator` selbst benachrichtigt
    /// nur, wenn `viewModel` neu GESETZT wird, nicht wenn sich Werte DARIN
    /// (wie `isPlaying`) ändern.
    @ViewBuilder
    private var playButton: some View {
        if let vm = coordinator.viewModel, coordinator.activeItem?.id == entry.id {
            ActivePlayButton(viewModel: vm, shape: buttonShape)
        } else {
            Button {
                Task { await coordinator.open(item: entry.item) }
            } label: {
                HStack {
                    if isThisBookLoading {
                        ProgressView()
                        Text("Wird gestartet…")
                    } else {
                        Image(systemName: "play.fill")
                        Text(playButtonLabel)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(.primary)
            }
            .modifier(AdaptiveGlassBackground(shape: buttonShape))
            .disabled(isThisBookLoading)
            .padding(.horizontal)
        }
    }

    // MARK: - Zusatzinfos

    @ViewBuilder
    private var infoSection: some View {
        let narrator = detail?.media.metadata?.narratorName
        let series = detail?.media.metadata?.seriesName
        let genres = detail?.media.metadata?.genres
        let year = detail?.media.metadata?.publishedYear?.value
        let duration = detail?.media.duration

        let hasAnyInfo = [narrator, series, year].contains { $0?.isEmpty == false }
            || (genres?.isEmpty == false)
            || (duration ?? 0) > 0

        if hasAnyInfo {
            VStack(alignment: .leading, spacing: 6) {
                if let series, !series.isEmpty {
                    infoRow(label: "Serie", value: series)
                }
                if let narrator, !narrator.isEmpty {
                    infoRow(label: "Erzähler", value: narrator)
                }
                if let genres, !genres.isEmpty {
                    infoRow(label: "Genre", value: genres.joined(separator: ", "))
                }
                if let year, !year.isEmpty {
                    infoRow(label: "Erschienen", value: year)
                }
                if let duration, duration > 0 {
                    infoRow(label: "Gesamtdauer", value: formattedDuration(duration))
                }
            }
            .padding(.horizontal)
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.subheadline)
            Spacer()
        }
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let totalMinutes = Int(seconds / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours) Std. \(minutes) Min." : "\(minutes) Min."
    }

    // MARK: - Als gehört markieren

    private var isFinished: Bool {
        isFinishedOverride ?? (entry.progress?.isFinished ?? false)
    }

    private var markAsFinishedButton: some View {
        Button {
            Task { await toggleFinishedMark() }
        } label: {
            Label(
                isFinished ? "Als ungehört markieren" : "Als gehört markieren",
                systemImage: isFinished ? "checkmark.circle.fill" : "checkmark.circle"
            )
            .font(.subheadline)
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .modifier(AdaptiveGlassBackground(shape: Capsule()))
        .padding(.horizontal)
    }

    private func toggleFinishedMark() async {
        errorMessage = nil
        do {
            // Frischen Stand holen statt dem evtl. veralteten `detail` zu
            // vertrauen — und danach IMMER currentTime + duration + isFinished
            // zusammen schicken. Ein PATCH mit nur {"isFinished": ...} überlässt
            // dem Server, was er mit currentTime macht — genau das führte dazu,
            // dass nach gehört→ungehört der reale Fortschritt verloren ging.
            let fresh = try await coordinator.apiClient.fetchItemDetail(itemId: entry.id)
            let duration = fresh.media.duration ?? 0
            let currentTime = fresh.userMediaProgress?.currentTime ?? 0

            if isFinished {
                // Ungehört markieren: realen Fortschritt unverändert lassen,
                // nur das Flag kippen.
                try await coordinator.apiClient.updateProgress(
                    itemId: entry.id, currentTime: currentTime, duration: duration, isFinished: false
                )
                isFinishedOverride = false
            } else {
                // Gehört markieren: Fortschritt explizit auf Buchende setzen.
                try await coordinator.apiClient.updateProgress(
                    itemId: entry.id, currentTime: duration, duration: duration, isFinished: true
                )
                isFinishedOverride = true
            }
            // Ohne das hier würde die Bibliotheksliste weiter den alten Stand
            // zeigen (Prozentzahl statt Häkchen), bis die App das nächste Mal
            // in den Vordergrund kommt.
            await libraryViewModel.refreshProgress()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Download

    @ViewBuilder
    private var downloadSection: some View {
        if downloadManager.isDownloaded(itemId: entry.id) {
            HStack {
                Label("Für offline verfügbar", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
                Spacer()
                Button(role: .destructive) {
                    downloadManager.deleteDownload(itemId: entry.id)
                } label: {
                    Image(systemName: "trash")
                }
            }
            .padding(.horizontal)
        } else if let progress = downloadManager.downloadProgress[entry.id] {
            HStack(spacing: 8) {
                ProgressView(value: progress)
                Text("\(Int((progress * 100).rounded())) %")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            .padding(.horizontal)
        } else {
            Button {
                Task { await startDownloadWithWiFiCheck() }
            } label: {
                Label("Für offline speichern", systemImage: "arrow.down.circle")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            .modifier(AdaptiveGlassBackground(shape: Capsule()))
            .disabled(detail == nil)
            .padding(.horizontal)
        }
    }

    private func startDownloadWithWiFiCheck() async {
        if await NetworkStatus.isOnWiFi() {
            await reallyStartDownload()
        } else {
            showWiFiWarning = true
        }
    }

    private func reallyStartDownload() async {
        guard let detail else { return }
        await downloadManager.download(item: detail, apiClient: coordinator.apiClient)
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

/// Play/Pause-Button für den Fall, dass DIESES Buch bereits die aktive
/// Session ist. Eigene View, damit `viewModel` echt als @ObservedObject
/// beobachtet wird — sonst reagiert der Button nicht zuverlässig auf
/// Play/Pause-Wechsel (siehe Erklärung in `BookDetailScreen.playButton`).
private struct ActivePlayButton<S: Shape>: View {
    @ObservedObject var viewModel: PlayerViewModel
    let shape: S

    var body: some View {
        Button {
            viewModel.togglePlayPause()
        } label: {
            HStack {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                Text(viewModel.isPlaying ? "Pause" : "Fortsetzen")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(.primary)
        }
        .modifier(AdaptiveGlassBackground(shape: shape))
        .padding(.horizontal)
    }
}
