import ActivityKit
import SwiftUI
import WidgetKit

/// Widget-Bundle der Extension. Diese Datei gehört NUR zum Widget-Extension-
/// Target (siehe ANLEITUNG.md) — zusätzlich braucht das Target
/// `Sources/Models/PlaybackActivityAttributes.swift` als Mitglied.
@main
struct MaerWidgetBundle: WidgetBundle {
    var body: some Widget {
        ContinueListeningWidget()
        PlaybackLiveActivity()
    }
}

/// Erscheint NUR während eines Schlaf-Timers (die App startet die Aktivität
/// ausschließlich dort): Mond + Countdown, dazu Titel/Kapitel. Während
/// normaler Wiedergabe liefert Apples „Now Playing" Insel-Präsenz und
/// Lock-Screen-Player selbst — nichts wird gedoppelt.
struct PlaybackLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlaybackActivityAttributes.self) { context in
            // System-Standard-Hintergrund (adaptiv hell/dunkel) statt
            // App-Look: Live Activities sollen sich iOS anpassen.
            LockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusIcon(state: context.state)
                        .font(.title2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CountdownText(state: context.state)
                        .font(.title3.bold())
                        .monospacedDigit()
                        .frame(maxWidth: 72, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.bookTitle)
                            .font(.subheadline.bold())
                            .lineLimit(1)
                        if let chapter = context.state.chapterName {
                            Text(chapter)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                StatusIcon(state: context.state)
            } compactTrailing: {
                // Timer-Text ist gierig und würde sonst mittig schwimmen —
                // fest nach rechts außen begrenzen.
                CountdownText(state: context.state)
                    .font(.caption2)
                    .monospacedDigit()
                    .frame(maxWidth: 52, alignment: .trailing)
            } minimal: {
                StatusIcon(state: context.state)
            }
        }
    }
}

/// Sperrbildschirm: bewusst EIN schmaler Streifen unter Apples Player.
private struct LockScreenView: View {
    let context: ActivityViewContext<PlaybackActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            StatusIcon(state: context.state)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(context.attributes.bookTitle)
                    .font(.footnote.bold())
                    .lineLimit(1)
                if let chapter = context.state.chapterName {
                    Text(chapter)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            CountdownText(state: context.state)
                .font(.callout.bold())
                .monospacedDigit()
                .frame(maxWidth: 80, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Mond bei laufendem Schlaf-Timer, sonst Play/Pause-Glyph.
private struct StatusIcon: View {
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        Image(systemName: state.sleepEndDate != nil
            ? "moon.zzz.fill"
            : (state.isPlaying ? "play.fill" : "pause.fill"))
    }
}

/// Schlaf-Countdown gewinnt; sonst Kapitel-Countdown (kurz genug für die
/// kompakte Pille). Live NUR während der Wiedergabe — bei Pause frieren
/// beide ein (die App zählt den Schlaf-Timer nur beim Hören herunter).
private struct CountdownText: View {
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        if let end = state.sleepEndDate ?? state.chapterEndDate {
            if state.isPlaying {
                Text(timerInterval: state.capturedAt...max(end, state.capturedAt), countsDown: true)
            } else {
                Text(frozen(until: end))
            }
        } else {
            Image(systemName: "headphones")
        }
    }

    private func frozen(until end: Date) -> String {
        let remaining = max(0, end.timeIntervalSince(state.capturedAt))
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        let seconds = Int(remaining) % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
