// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// A few seconds of silence as a WAV file, built in memory. The UI harness
/// hands it to the seed stations and seed episodes as their audio, so a
/// journey plays without the network and without a sound. Pure: a header
/// of 44 bytes and zeroed 16-bit mono samples, nothing else.
nonisolated enum SilentAudio {
    static func wav(seconds: Double = 3, sampleRate: Int = 8_000) -> Data {
        let frames = Int(seconds * Double(sampleRate))
        let bytesPerFrame = 2                       // 16-bit, one channel
        let dataSize = frames * bytesPerFrame
        var out = Data(capacity: 44 + dataSize)
        func ascii(_ s: String) { out.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { var le = UInt32(v).littleEndian; withUnsafeBytes(of: &le) { out.append(contentsOf: $0) } }
        func u16(_ v: Int) { var le = UInt16(v).littleEndian; withUnsafeBytes(of: &le) { out.append(contentsOf: $0) } }
        ascii("RIFF"); u32(36 + dataSize); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1)                       // PCM, mono
        u32(sampleRate); u32(sampleRate * bytesPerFrame); u16(bytesPerFrame); u16(16)
        ascii("data"); u32(dataSize)
        out.append(Data(count: dataSize))
        return out
    }
}
