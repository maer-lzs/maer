// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import Combine
import AVFoundation
import UIKit
import OSLog

/// Drive mode (for users without CarPlay): a VARIANT of the full player.
/// Same state, different layout. No second truth about what plays.
/// Guiding rule: glanceable, not readable. Sub-second glances, buttons hit
/// without aiming. It is an INTERACTION mode, not a safety promise.
@MainActor
final class DriveModeController: ObservableObject {
    static let shared = DriveModeController()
    private init() {}

    @Published private(set) var isActive = false
    /// Dim overlay after ~30 s without touch; any tap lifts it.
    @Published var dimmed = false
    private var dimTask: Task<Void, Never>?

    /// The ONE user-chosen car audio route (portName+UID remembered). We
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
    /// guaranteed re-enabled on exit, on background and in error paths.
    /// A stuck disable silently drains the battery.
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

    /// Auto-start is an EXPLICIT opt-in (default OFF). Nothing
    /// starts by itself just because a Bluetooth device connects.
    var autoStartEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppStorageKeys.driveModeAutoStart)
    }

    /// Route change hook (wired to AVAudioSession.routeChangeNotification):
    /// auto-enter ONLY with the opt-in toggle on AND the remembered car route
    /// connecting; on disconnect an active mode EXITS (decision: leaving the
    /// car ends the drive. Reported). The decision itself is pure (tested):
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
    /// toggle-independent. An active mode tied to the chosen device ends
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

    /// Pure candidate filter. The picker offers EXTERNAL routes
    /// only. The built-in speaker/receiver were listed before (a pointless
    /// "car audio" choice that crowded the real device out); every Bluetooth
    /// flavor plus CarPlay/USB/headphone ports stays in.
    nonisolated static let carPortTypes: Set<String> = [
        AVAudioSession.Port.bluetoothA2DP.rawValue,
        AVAudioSession.Port.bluetoothHFP.rawValue,
        AVAudioSession.Port.bluetoothLE.rawValue,
        AVAudioSession.Port.carAudio.rawValue,
        AVAudioSession.Port.usbAudio.rawValue,
        AVAudioSession.Port.headphones.rawValue,
    ]

    nonisolated static func carAudioCandidates(
        _ outputs: [(uid: String, name: String, portType: String)]
    ) -> [(uid: String, name: String)] {
        outputs.filter { carPortTypes.contains($0.portType) }.map { ($0.uid, $0.name) }
    }

    /// The picker list. CONNECTED route outputs plus the
    /// paired devices `availableInputs` reports, deduped by uid, the
    /// connected ones first (they are what the user is most likely picking).
    /// A remembered device stays in the list even when neither source names
    /// it right now, so the choice never silently disappears.
    nonisolated static func pickerList(
        routeOutputs: [(uid: String, name: String, portType: String)],
        availableInputs: [(uid: String, name: String, portType: String)],
        remembered: (uid: String, name: String)?
    ) -> [(uid: String, name: String)] {
        var out: [(uid: String, name: String)] = []
        var seen = Set<String>()
        for candidate in carAudioCandidates(routeOutputs) + carAudioCandidates(availableInputs)
        where seen.insert(candidate.uid).inserted {
            out.append(candidate)
        }
        if let remembered, !remembered.uid.isEmpty, seen.insert(remembered.uid).inserted {
            out.append(remembered)
        }
        return out
    }

    /// The picker candidates: no longer only the CONNECTED route. Apple
    /// hands out the paired audio devices via `availableInputs` (Bluetooth
    /// HFP ports carry `portName` and `uid`), without CoreBluetooth and
    /// without any permission, so the zero-permission rule holds.
    ///
    /// Honest limit: `availableInputs` only lists devices with INPUT
    /// capability (hands-free kits, headsets, car radios. The drive-mode
    /// case is well covered); a pure A2DP speaker without a microphone can
    /// be missing. That is why the connected route stays a source and the
    /// footnote says devices appear once paired and in range.
    nonisolated static func pickerCandidates() -> [(uid: String, name: String)] {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
            .map { (uid: $0.uid, name: $0.portName, portType: $0.portType.rawValue) }
        for output in outputs {
            Logger.library.notice("DRIVEMODE route: \(output.name, privacy: .public) type=\(output.portType, privacy: .public)")
        }
        let inputs = (session.availableInputs ?? [])
            .map { (uid: $0.uid, name: $0.portName, portType: $0.portType.rawValue) }
        let remembered = UserDefaults.standard.string(forKey: AppStorageKeys.driveModeCarRouteUID)
            .flatMap { uid -> (uid: String, name: String)? in
                let name = UserDefaults.standard.string(forKey: AppStorageKeys.driveModeCarRouteName) ?? uid
                return uid.isEmpty ? nil : (uid: uid, name: name)
            }
        let list = pickerList(routeOutputs: outputs, availableInputs: inputs, remembered: remembered)
        Logger.library.notice("DRIVE bt list available=\(inputs.count) route=\(outputs.count) remembered=\(remembered?.name ?? "-", privacy: .public) selected=\(list.count)")
        return list
    }
}
