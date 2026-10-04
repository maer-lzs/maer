// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

#if DEBUG
/// The one answer to "does this process run under a test?", in its two
/// halves. DEBUG only, so the shipped app never asks.
nonisolated enum TestProcess {
    /// The unit test host: XCTest names its configuration file in the
    /// environment of the process it runs the unit tests in.
    static let isUnitTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// The UI test harness: the app started by a journey with a `-uitest`
    /// argument.
    static var isUITestHarness: Bool { UITestSeed.isHarness }

    /// Either half: the shared services that must stay silent under any test.
    static var isUnderTest: Bool { isUnitTestHost || isUITestHarness }
}
#endif
