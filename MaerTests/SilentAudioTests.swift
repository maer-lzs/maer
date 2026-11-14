// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import AVFoundation
@testable import Maer

/// The silence the harness plays: a WAV the system decoder accepts, of the
/// length asked for, and nothing but zeros in it.
struct SilentAudioTests {
    @Test("header and length are right; the system decoder reads the file and names the duration")
    func headerLengthAndDecoder() throws {
        let data = SilentAudio.wav(seconds: 2, sampleRate: 8_000)
        #expect(data.count == 44 + 2 * 8_000 * 2)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: data[36..<40], as: UTF8.self) == "data")
        #expect(data.suffix(from: 44).allSatisfy { $0 == 0 }, "silence is zeros")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 8_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(abs(Double(file.length) / file.fileFormat.sampleRate - 2) < 0.001)
    }
}
#endif
