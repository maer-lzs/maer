import SwiftUI
import UIKit

/// Detailseite eines Buchs: Cover, Titel, Autor, Beschreibung und ein
/// Play-Button, der die Wiedergabe im Coordinator startet und zum vollen
/// Player navigiert. Wird beim Tippen auf ein Buch in der Bibliothek gezeigt.
///
/// Drei Layouts je nach verfügbarem Platz:
/// - iPhone Hochformat: großes Cover über die volle Breite mit Fade-Out
/// - iPhone Querformat und iPad: Cover links, Titel/Infos/Buttons rechts
///   daneben (mehr Platz durch die Breite sinnvoll genutzt statt nur
///   verkleinert)
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
    @State private var descriptionExpanded = false
    @StateObject private var colorLoader = CoverColorLoader()

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var buttonShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    /// Nebeneinander-Layout (Cover links, Rest rechts) auf dem iPad in jeder
    /// Ausrichtung, und auf dem iPhone nur im Querformat (dort wird
    /// `verticalSizeClass` zu `.compact`) — im iPhone-Hochformat bleibt die
    /// große Hero-Cover-Ansicht.
    private var useSideBySideLayout: Bool {
        !isPhone || verticalSizeClass == .compact
    }

    /// Bewusst Screen-Breite statt GeometryReader — das Cover soll immer exakt
    /// die volle Gerätebreite nutzen (nicht irgendeine ScrollView-Breite).
    /// Über die WindowScene statt UIScreen.main (deprecated iOS 26).
    private var heroCoverSize: CGFloat {
        let screen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }.first
        return screen?.bounds.width ?? 400
    }

    private var heroCover: some View {
        coverImageContent
            .frame(width: heroCoverSize, height: heroCoverSize)
            .clipped()
            .frame(maxWidth: .infinity)
    }

    private var coverImageContent: some View {
        CachedAsyncImage(url: coordinator.apiClient.coverURL(forItemId: entry.id)) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .overlay(Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary))
        }
    }

    /// Titel/Autor/Fortschritt — zentriert und weiß für die Hero-Ansicht (die
    /// liegt auf dem farbigen Verlaufs-Hintergrund, da reicht `.primary`
    /// nicht, das wäre im hellen Systemmodus schwarz und unlesbar),
    /// linksbündig mit normalen adaptiven Farben fürs Nebeneinander-Layout
    /// (dort ist der Hintergrund der normale Systemhintergrund).
    private func titleBlock(alignment: HorizontalAlignment) -> some View {
        let isHero = alignment == .center
        return VStack(alignment: alignment, spacing: 6) {
            Text(entry.item.title)
                .font(.title2).bold()
                .multilineTextAlignment(isHero ? .center : .leading)
                .foregroundStyle(isHero ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            if let author = entry.item.author {
                Text(author)
                    .font(.subheadline)
                    .foregroundStyle(isHero ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
            }
            if let p = entry.progress, p.isStarted, !isFinished {
                // Fortschritt konsistent zur Bibliothek: Balken + Restzeit.
                ProgressView(value: p.fraction)
                    .tint(AppTheme.accent)
                    .frame(maxWidth: 220)
                    .padding(.top, 2)
                Text(p.remainingText(bookDuration: entry.item.media?.duration) ?? "\(p.percentInt) % gehört")
                    .font(.caption)
                    .foregroundStyle(isHero ? AnyShapeStyle(.white.opacity(0.6)) : AnyShapeStyle(.secondary))
            } else if isFinished {
                Text("Abgeschlossen")
                    .font(.caption)
                    .foregroundStyle(isHero ? AnyShapeStyle(.white.opacity(0.6)) : AnyShapeStyle(.secondary))
            }
        }
    }

    /// Cover links, Titel/Infos/Buttons rechts daneben — für iPad und
    /// iPhone-Querformat, wo die Breite mehr hergibt als nur ein größeres
    /// oder kleineres Cover.
    private var sideBySideHeader: some View {
        HStack(alignment: .top, spacing: 20) {
            BookCoverView(
                url: coordinator.apiClient.coverURL(forItemId: entry.id),
                progress: entry.progress,
                itemId: entry.id,
                size: 180
            )
            VStack(alignment: .leading, spacing: 14) {
                titleBlock(alignment: .leading)
                infoSection(withPadding: false)
                playArea(withPadding: false)
                HStack(spacing: 12) {
                    downloadSection
                    markAsFinishedButton
                }
            }
        }
        .padding(.horizontal)
        .padding(.top)
    }

    var body: some View {
        ZStack {
            if !useSideBySideLayout {
                // Verlauf als HINTERGRUND für den ganzen oberen Bereich, wie
                // beim großen Player — Cover und Titel liegen frei darüber.
                // Kein Schwarz mehr ganz oben (startet direkt mit der
                // Cover-Farbe), wird bis knapp unter die Buttons hin
                // weich zu Schwarz und bleibt danach schwarz.
                LinearGradient(
                    stops: [
                        .init(color: colorLoader.topAccent, location: 0.00),
                        .init(color: colorLoader.topAccent.opacity(0.85), location: 0.45),
                        .init(color: .black.opacity(0.75), location: 0.85)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }

            ScrollView {
                VStack(spacing: 20) {
                    if useSideBySideLayout {
                        sideBySideHeader
                            // Gleicht aus, dass die ScrollView jetzt die obere
                            // Sicherheitszone ignoriert (nötig fürs Hero-Cover
                            // unten) — hier soll der Inhalt aber ganz normal
                            // unter Statusleiste/Navigationsleiste anfangen.
                            .padding(.top, 54)
                    } else {
                        VStack(spacing: 8) {
                            heroCover
                            titleBlock(alignment: .center)
                                .padding(.horizontal)
                        }
                        infoSection(withPadding: true)
                        playArea(withPadding: true)
                        HStack(spacing: 12) {
                            downloadSection
                            markAsFinishedButton
                        }
                        .padding(.horizontal)
                    }

                    if let chapters = detail?.media.chapters, !chapters.isEmpty {
                        chapterLink(chapters, isHero: !useSideBySideLayout)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }

                    if let description = detail?.media.metadata?.description, !description.isEmpty {
                        let text = Self.plainText(fromHTML: description)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Beschreibung")
                                .font(.headline)
                            Text(text)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .lineLimit(descriptionExpanded ? nil : 7)
                            // Auf-/Zuklappen nur, wenn der Text das braucht.
                            if text.count > 350 {
                                Button(descriptionExpanded ? "Weniger anzeigen" : "Mehr anzeigen") {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        descriptionExpanded.toggle()
                                    }
                                }
                                .font(.subheadline.bold())
                                .tint(AppTheme.accent)
                            }
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
            // Ohne das hier hat die ScrollView selbst eine blickdichte
            // Standard-Füllung, die über dem Verlauf im Hintergrund liegt —
            // der wäre dann komplett unsichtbar gewesen, nicht nur "hinter
            // den Textblöcken", wie es sich angefühlt haben muss.
            .scrollContentBackground(.hidden)
            // Muss auf der ScrollView selbst sitzen, nicht auf dem Cover
            // darin — ein verschachteltes Kind kann die Sicherheitszone
            // nicht "durchbrechen", die ScrollView schneidet ihren Inhalt an
            // ihren eigenen Grenzen ab, egal was ein Kind-Element möchte.
            .ignoresSafeArea(edges: .top)
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
        .task(id: entry.id) {
            await colorLoader.load(from: coordinator.apiClient.coverURL(forItemId: entry.id))
        }
    }

    // MARK: - Play/Pause

    /// Play-Button + optionaler „Von Anfang starten"-Link darunter.
    @ViewBuilder
    private func playArea(withPadding: Bool) -> some View {
        VStack(spacing: 8) {
            playButton(withPadding: withPadding)
            if entry.progress?.isStarted == true || isFinished {
                Button("Von Anfang starten") {
                    Task { await restartFromBeginning() }
                }
                .font(.footnote)
                .foregroundStyle(withPadding ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.secondary))
            }
        }
    }

    /// Bewusster Neustart: Sprung auf 0 gilt als Nutzeraktion und wird sofort
    /// gesynct (kein Konflikt-Dialog).
    private func restartFromBeginning() async {
        if coordinator.activeItem?.id == entry.id, let vm = coordinator.viewModel {
            await vm.seek(to: 0)
            vm.play()
        } else {
            await coordinator.open(item: entry.item)
            await coordinator.viewModel?.seek(to: 0)
        }
    }

    // MARK: - Kapitel

    private func chapterLink(_ chapters: [ABSChapter], isHero: Bool) -> some View {
        NavigationLink {
            DetailChapterList(
                bookTitle: entry.item.title,
                chapters: chapters,
                coordinator: coordinator,
                entry: entry
            )
        } label: {
            HStack {
                Label("Kapitel", systemImage: "list.bullet")
                    .font(.subheadline)
                    .foregroundStyle(isHero ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                Spacer()
                Text("\(chapters.count)")
                    .font(.subheadline)
                    .foregroundStyle(isHero ? AnyShapeStyle(.white.opacity(0.6)) : AnyShapeStyle(.secondary))
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(isHero ? AnyShapeStyle(.white.opacity(0.6)) : AnyShapeStyle(.secondary))
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
        }
        .modifier(AdaptiveGlassBackground(shape: buttonShape))
        .padding(.horizontal)
    }

    /// Ist DIESES Buch gerade die aktive Session, wird eine eigene, echt
    /// beobachtende Unteransicht genutzt (siehe `ActivePlayButton`) — sonst
    /// reagiert der Button nicht zuverlässig auf Play/Pause-Wechsel, aus
    /// demselben Grund wie beim Mini-Player: `coordinator` selbst benachrichtigt
    /// nur, wenn `viewModel` neu GESETZT wird, nicht wenn sich Werte DARIN
    /// (wie `isPlaying`) ändern.
    @ViewBuilder
    private func playButton(withPadding: Bool) -> some View {
        Group {
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
            }
        }
        .padding(.horizontal, withPadding ? 16 : 0)
    }

    // MARK: - Zusatzinfos

    @ViewBuilder
    private func infoSection(withPadding: Bool) -> some View {
        let narrator = detail?.media.metadata?.narratorName
        let series = detail?.media.metadata?.seriesName
        let genres = detail?.media.metadata?.genres
        let year = detail?.media.metadata?.publishedYear?.value
        let duration = detail?.media.duration

        let hasAnyInfo = [narrator, series, year].contains { $0?.isEmpty == false }
            || (genres?.isEmpty == false)
            || (duration ?? 0) > 0

        // `withPadding` verrät zugleich, ob das die Hero-Ansicht ist (liegt
        // auf dem farbigen Verlaufs-Hintergrund, braucht also weißen Text)
        // oder das Nebeneinander-Layout (normaler Systemhintergrund, normale
        // adaptive Farben reichen).
        if hasAnyInfo {
            VStack(alignment: .leading, spacing: 6) {
                if let series, !series.isEmpty {
                    infoRow(label: "Serie", value: series, isHero: withPadding)
                }
                if let narrator, !narrator.isEmpty {
                    infoRow(label: "Erzähler", value: narrator, isHero: withPadding)
                }
                if let genres, !genres.isEmpty {
                    infoRow(label: "Genre", value: genres.joined(separator: ", "), isHero: withPadding)
                }
                if let year, !year.isEmpty {
                    infoRow(label: "Erschienen", value: year, isHero: withPadding)
                }
                if let duration, duration > 0 {
                    infoRow(label: "Gesamtdauer", value: formattedDuration(duration), isHero: withPadding)
                }
            }
            .padding(.horizontal, withPadding ? 16 : 0)
        }
    }

    private func infoRow(label: String, value: String, isHero: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(isHero ? AnyShapeStyle(.white.opacity(0.6)) : AnyShapeStyle(.secondary))
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(isHero ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            Spacer()
        }
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let totalMinutes = Int(seconds / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours) Std. \(minutes) Min." : "\(minutes) Min."
    }

    /// Server-Beschreibungen enthalten oft rohes HTML (`<p>`, `<br>`, …) statt
    /// reinem Text. Wandelt Absatz-/Zeilenumbrüche in echte Umbrüche um,
    /// entfernt alle übrigen Tags und dekodiert die gängigsten
    /// HTML-Entitäten — bewusst eine einfache Bereinigung statt einer vollen
    /// HTML-Darstellung, das reicht für Klartext-Beschreibungen.
    private static func plainText(fromHTML html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.caseInsensitive, .regularExpression])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities: [String: String] = [
            "&amp;": "&", "&nbsp;": " ", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">"
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .modifier(AdaptiveGlassBackground(shape: Capsule()))
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

            let target = !isFinished
            let writeTime = target ? duration : currentTime
            do {
                try await coordinator.apiClient.updateProgress(
                    itemId: entry.id, currentTime: writeTime, duration: duration, isFinished: target
                )
            } catch {
                // Statusentscheidung nicht verlieren: queuen, Flush reicht nach.
                SyncQueue.shared.enqueue(
                    itemId: entry.id, currentTime: writeTime, duration: duration, isFinished: target
                )
            }
            isFinishedOverride = target
            // Ohne das hier würde die Bibliotheksliste weiter den alten Stand
            // zeigen (Prozentzahl statt Häkchen), bis die App das nächste Mal
            // in den Vordergrund kommt.
            await libraryViewModel.refreshProgress()
        } catch {
            if NetworkStatus.isOfflineError(error) {
                // Schon der Frisch-Abruf scheiterte (offline): mit lokal
                // bekannten Werten queuen statt die Entscheidung zu verlieren.
                let target = !isFinished
                let duration = entry.item.media?.duration ?? 0
                let currentTime = (entry.progress?.fraction ?? 0) * duration
                SyncQueue.shared.enqueue(
                    itemId: entry.id,
                    currentTime: target ? duration : currentTime,
                    duration: duration,
                    isFinished: target
                )
                isFinishedOverride = target
            } else {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    // MARK: - Download

    @ViewBuilder
    private var downloadSection: some View {
        Group {
            if downloadManager.isDownloaded(itemId: entry.id) {
                HStack {
                    Label("Offline verfügbar", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline)
                    // Belegter Speicher dieses Buchs.
                    Text(ByteCountFormatter.string(
                        fromByteCount: downloadManager.downloadSize(forItemId: entry.id),
                        countStyle: .file
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        downloadManager.deleteDownload(itemId: entry.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            } else if let progress = downloadManager.downloadProgress[entry.id] {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                    Text("\(Int((progress * 100).rounded())) %")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            } else {
                Button {
                    Task { await startDownloadWithWiFiCheck() }
                } label: {
                    Label("Offline speichern", systemImage: "arrow.down.circle")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .modifier(AdaptiveGlassBackground(shape: Capsule()))
                .disabled(detail == nil)
            }
        }
        .frame(maxWidth: .infinity)
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
    }
}
