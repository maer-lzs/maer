import ActivityKit
import SwiftUI
import WidgetKit
import UIKit   // S15b: adaptive system colors for the activity background tint

/// Widget bundle of the extension. This file belongs ONLY to the widget
/// extension target (see ANLEITUNG.md) — the target also needs
/// `Sources/Models/PlaybackActivityAttributes.swift` as a member.
@main
struct MaerWidgetBundle: WidgetBundle {
    var body: some Widget {
        ContinueListeningWidget()
        PodcastUpNextWidget()
        PlaybackLiveActivity()
    }
}

/// Appears ONLY during a sleep timer (the app starts the activity only there):
/// moon + countdown, plus title/chapter. During normal playback Apple's "Now
/// Playing" provides island presence and the lock-screen player itself —
/// nothing is duplicated.
struct PlaybackLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlaybackActivityAttributes.self) { context in
            // S15e: NO fixed background tint or foreground color. the owner runs the
            // iOS Glass design (system "Transparent"/"Tinted") — a fixed tint (the
            // earlier S15b–d attempts) overrode the system Glass and fought its
            // light/dark rendering. Without a tint the activity respects the
            // system Glass + appearance environment, matching the system player.
            LockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    // Apple media convention: artwork in the expanded island.
                    CoverThumb(state: context.state, size: 40)
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
                // The timer text is greedy and would otherwise float centered —
                // pin it to the far right.
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

/// Lock screen: Apple media-activity layout — leading artwork (with the sleep/
/// play status as a corner badge), title + chapter, trailing countdown.
private struct LockScreenView: View {
    let context: ActivityViewContext<PlaybackActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            CoverThumb(state: context.state, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.bookTitle)
                    .font(.footnote.bold())
                    .lineLimit(1)
                if let chapter = context.state.chapterName {
                    Text(chapter)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let author = context.attributes.author {
                    Text(author)
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
        // S15f: iOS 26 applies its Liquid Glass to the Live Activity ONLY when no
        // activityBackgroundTint is set (S15e removed those). A container
        // background is still required, but it must be CLEAR — an opaque one
        // (the earlier `Color(.systemBackground)`) fills the base and renders the
        // "Transparent" appearance dark. A clear base lets the system draw its own
        // glass in BOTH appearances (tinted → tint, transparent → wallpaper glass).
        .containerBackground(for: .widget) { Color.clear }
    }
}

/// Book/album cover from the shared app-group container (same PNG the home-
/// screen widgets use), with the sleep/play status glyph as a corner badge.
private struct CoverThumb: View {
    let state: PlaybackActivityAttributes.ContentState
    var size: CGFloat

    var body: some View {
        Group {
            if let cover = Self.cover {
                Image(uiImage: cover)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                    .fill(.secondary.opacity(0.2))
                    .overlay(Image(systemName: "headphones").foregroundStyle(.secondary))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            // S15c: system-neutral badge instead of a hard black disc — a
            // frosted material with an adaptive glyph, readable over any cover
            // in both light and dark, matching the app's other status chips.
            StatusIcon(state: state)
                .font(.system(size: size * 0.28))
                .foregroundStyle(.primary)
                .padding(size * 0.09)
                .background(.ultraThinMaterial, in: Circle())
                .padding(2)
        }
    }

    /// Small PNG, read on demand (Live Activity views re-render on state change,
    /// not per frame). Same source as `ContinueListeningWidget`.
    static var cover: UIImage? {
        guard let url = WidgetSnapshot.coverURL, let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}

/// Moon while a sleep timer runs, otherwise the play/pause glyph.
private struct StatusIcon: View {
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        Image(systemName: state.sleepEndDate != nil
            ? "moon.zzz.fill"
            : (state.isPlaying ? "play.fill" : "pause.fill"))
    }
}

/// The sleep countdown wins; otherwise the chapter countdown (short enough for
/// the compact pill). Live ONLY during playback — both freeze when paused (the
/// app only counts the sleep timer down while listening).
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
