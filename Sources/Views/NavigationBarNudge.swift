// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import UIKit
import OSLog

/// Damping stage (a): repeated title state transitions on a live large-title
/// bar can drop the title permanently on
/// iOS 26. The one-tick retarget (stage b) alone proved flaky over long test
/// runs, and a BLIND bar nudge (sizeToFit/prefersLargeTitles on every flip)
/// made things worse — anything extra on the live bar feeds the bug. So the
/// nudge DETECTS first: only when the expected title label is verifiably
/// absent from the bar does it force a large-title rebuild by toggling
/// `largeTitleDisplayMode` off and back on (public API only).
///
/// This is the single, tightly-scoped introspection point of the app (no
/// scattering): `Probe` is a zero-size leaf inside the NavigationStack that
/// captures the stack's `UINavigationController`. Root fix remains the
/// per-tab stack structure.
enum NavigationBarNudge {
    private static weak var navigationController: UINavigationController?

    /// Zero-size capture leaf — mount exactly once inside the stack content.
    struct Probe: UIViewRepresentable {
        func makeUIView(context: Context) -> ProbeView { ProbeView() }
        func updateUIView(_ uiView: ProbeView, context: Context) {}
    }

    final class ProbeView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var responder: UIResponder? = next
            while let r = responder {
                if let vc = r as? UIViewController {
                    NavigationBarNudge.navigationController =
                        vc.navigationController ?? (vc as? UINavigationController)
                    break
                }
                responder = r.next
            }
        }
    }

    /// Check (after the flip transition has settled) whether the bar still
    /// shows `expectedTitle`; if the label is gone, rebuild the large title.
    /// A second confirmation check avoids acting on a mid-animation snapshot.
    static func nudgeIfTitleMissing(expectedTitle: String) {
        check(expectedTitle: expectedTitle, delay: 0.35, confirmed: false)
    }

    private static func check(expectedTitle: String, delay: Double, confirmed: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let nav = navigationController, let top = nav.topViewController else {
                Logger.library.notice("titleNudge: no captured nav controller")
                return
            }
            // Only act on the root content (no pushed detail, whose bar
            // legitimately shows a different title), never mid-transition.
            guard nav.viewControllers.count == 1,
                  nav.transitionCoordinator == nil else {
                Logger.library.notice("titleNudge: skipped (pushed detail or mid-transition)")
                return
            }
            // A DELIBERATELY hidden bar (the search page hides its toolbar)
            // has no visible title BY DESIGN — the nudge must never fight
            // that state with rebuilds.
            guard !nav.isNavigationBarHidden, !nav.navigationBar.isHidden else {
                Logger.library.notice("titleNudge: skipped (bar deliberately hidden)")
                return
            }
            if barShowsTitle(nav.navigationBar, expectedTitle) {
                Logger.library.notice("titleNudge: healthy (\(expectedTitle, privacy: .public))")
                return
            }
            guard confirmed else {
                check(expectedTitle: expectedTitle, delay: 0.25, confirmed: true)
                return
            }
            // Rebuild: toggling the display mode forces the bar to recreate
            // its large-title view (the dropped label never comes back on
            // its own — probe-verified permanent loss).
            Logger.library.notice("titleNudge: TITLE MISSING (\(expectedTitle, privacy: .public)) -> rebuilding")
            top.navigationItem.largeTitleDisplayMode = .never
            DispatchQueue.main.async {
                top.navigationItem.largeTitleDisplayMode = .always
            }
        }
    }

    /// Public-API search: a VISIBLE UILabel in the bar hierarchy showing the
    /// title. Hidden/zero-alpha/zero-size labels don't count — the dropped
    /// title can leave its label in the tree while nothing is rendered.
    private static func barShowsTitle(_ bar: UINavigationBar, _ title: String) -> Bool {
        func scan(_ view: UIView) -> Bool {
            guard !view.isHidden, view.alpha > 0.01 else { return false }
            if let label = view as? UILabel, label.text == title,
               label.window != nil, label.bounds.width > 1 { return true }
            return view.subviews.contains { scan($0) }
        }
        return scan(bar)
    }
}
