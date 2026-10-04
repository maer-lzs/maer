// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Whether the network can be asked at all, the one question the services'
/// network paths put before a request. In production it is the path
/// monitor's answer. In the unit test host the door never asks the network
/// of the machine it runs on: without an answer set by the test it says the
/// network is there, so no witness that fakes a wire or serves on the
/// loopback depends on the host, and no suite has to remember to say so. A
/// witness that wants the offline side sets it (`Reachability.$assumed`);
/// the task-local answer reaches only the task that set it and the tasks
/// that task starts, never a neighbouring test.
nonisolated enum Reachability {
    #if DEBUG
    @TaskLocal static var assumed: Bool?
    #endif

    static func isConnected() async -> Bool {
        #if DEBUG
        if let assumed { return assumed }
        // The unit test host only, not the UI harness: a journey runs the
        // app on a simulator whose network is what the journey measures,
        // and its offline side must stay offline.
        if TestProcess.isUnitTestHost { return true }
        #endif
        return await NetworkMonitor.shared.isConnected
    }
}
