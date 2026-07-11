import ActivityKit
import SwiftUI
import WidgetKit

/// Widget-Bundle der Extension. Diese Datei gehört NUR zum Widget-Extension-
/// Target (siehe ANLEITUNG.md) — zusätzlich braucht das Target
/// `Sources/Models/PlaybackActivityAttributes.swift` als Mitglied.
@main
struct HoerregalWidgetBundle: WidgetBundle {
    var body: some Widget {
        PlaybackLiveActivity()
    }
}

struct PlaybackLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlaybackActivityAttributes.self) { context in
            // Lock screen banner.
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isPlaying ? "play.fill" : "pause.fill")
                        .foregroundStyle(.orange)
                        .font(.title2)
                }
                DynamicIslandExpandedRegion(.center) {
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
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressBar(state: context.state)
                }
            } compactLeading: {
                Image(systemName: context.state.isPlaying ? "play.fill" : "pause.fill")
                    .foregroundStyle(.orange)
            } compactTrailing: {
                Text(remainingText(context.state))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.orange)
            } minimal: {
                Image(systemName: "headphones")
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<PlaybackActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: context.state.isPlaying ? "play.fill" : "pause.fill")
                    .foregroundStyle(.orange)
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
                Spacer()
                Text(remainingText(context.state))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressBar(state: context.state)
        }
        .padding(14)
        .foregroundStyle(.white)
    }
}

/// Fortschritt: läuft die Wiedergabe, extrapoliert `timerInterval` selbst
/// weiter (kein Update-Traffic); pausiert bleibt der Balken statisch.
private struct ProgressBar: View {
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        if state.isPlaying {
            let start = state.capturedAt.addingTimeInterval(-state.currentTime)
            let end = state.capturedAt.addingTimeInterval(state.duration - state.currentTime)
            ProgressView(timerInterval: start...end, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .tint(.orange)
        } else {
            ProgressView(value: state.duration > 0 ? state.currentTime / state.duration : 0)
                .tint(.orange)
        }
    }
}

private func remainingText(_ state: PlaybackActivityAttributes.ContentState) -> String {
    let remaining = max(0, state.duration - state.currentTime)
    let hours = Int(remaining) / 3600
    let minutes = (Int(remaining) % 3600) / 60
    if hours > 0 { return "-\(hours):" + String(format: "%02d", minutes) + " h" }
    return "-\(minutes) min"
}
