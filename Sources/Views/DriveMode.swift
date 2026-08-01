// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Combine
import AVFoundation
import UIKit
import OSLog

/// Drive mode (for users without CarPlay): a VARIANT of the full player —
/// same state, different layout (Regel 2, no second truth about what plays).
/// Guiding rule: glanceable, not readable — sub-second glances, buttons hit
/// without aiming. It is an INTERACTION mode, not a safety promise.
@MainActor
final class DriveModeController: ObservableObject {
    static let shared = DriveModeController()
    private init() {}

    @Published private(set) var isActive = false
    /// Dim overlay after ~30 s without touch; any tap lifts it.
    @Published var dimmed = false
    private var dimTask: Task<Void, Never>?

    /// The ONE user-chosen car audio route (portName+UID remembered) — we
    /// never guess ("any A2DP device" would treat headphones as a car).
    var rememberedCarRouteUID: String? {
        get { UserDefaults.standard.string(forKey: AppStorageKeys.driveModeCarRouteUID) }
    }

    func enter() {
        guard !isActive else { return }
        isActive = true
        applyIdleTimer(true)
        scheduleDim()
        Logger.library.notice("drive mode entered")
    }

    func exit() {
        guard isActive else { return }
        isActive = false
        dimmed = false
        dimTask?.cancel()
        applyIdleTimer(false)
        Logger.library.notice("drive mode exited")
    }

    /// Idle-timer discipline: disabled ONLY while the mode is active, and
    /// guaranteed re-enabled on exit, on background and in error paths —
    /// a stuck disable silently drains the battery.
    private func applyIdleTimer(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }

    /// Called from scenePhase: background ALWAYS releases the idle timer;
    /// foreground re-applies it only while the mode is still active.
    func scenePhaseChanged(active: Bool) {
        applyIdleTimer(active && isActive)
    }

    func touched() {
        dimmed = false
        scheduleDim()
    }

    private func scheduleDim() {
        dimTask?.cancel()
        dimTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dimmed = true
        }
    }

    /// 9357955: auto-start is an EXPLICIT opt-in (default OFF) — nothing
    /// starts by itself just because a Bluetooth device connects.
    var autoStartEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppStorageKeys.driveModeAutoStart)
    }

    /// Route change hook (wired to AVAudioSession.routeChangeNotification):
    /// auto-enter ONLY with the opt-in toggle on AND the remembered car route
    /// connecting; on disconnect an active mode EXITS (decision: leaving the
    /// car ends the drive — reported). The decision itself is pure (tested):
    /// matching is STRICTLY the chosen device UID, never "any A2DP".
    func handleRouteChange() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        switch DriveModeController.routeChangeAction(
            autoStartEnabled: autoStartEnabled,
            rememberedUID: rememberedCarRouteUID,
            connectedUIDs: outputs.map(\.uid),
            isActive: isActive) {
        case .enter: enter()
        case .exit: exit()
        case nil: break
        }
    }

    nonisolated enum RouteAction { case enter, exit }

    /// Pure (tested): what a route change means. No remembered UID (or an
    /// orphaned empty one) → NEVER anything, regardless of what connects; the
    /// UID must match EXACTLY (a different A2DP device is a stranger); enter
    /// additionally requires the opt-in toggle. Exit on disconnect stays
    /// toggle-independent — an active mode tied to the chosen device ends
    /// when that device goes away.
    nonisolated static func routeChangeAction(autoStartEnabled: Bool,
                                              rememberedUID: String?,
                                              connectedUIDs: [String],
                                              isActive: Bool) -> RouteAction? {
        guard let uid = rememberedUID, !uid.isEmpty else { return nil }
        let connected = connectedUIDs.contains(uid)
        if connected, !isActive, autoStartEnabled { return .enter }
        if !connected, isActive { return .exit }
        return nil
    }

    /// The currently connected outputs, for the settings picker ("choose your
    /// car radio once").
    nonisolated static func currentOutputs() -> [(uid: String, name: String)] {
        AVAudioSession.sharedInstance().currentRoute.outputs.map { ($0.uid, $0.portName) }
    }
}
