// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Accelerate
import AVFoundation
import MediaToolbox
import Synchronization

/// The setting the filter plays with now, shared between the player and
/// the audio thread. A new setting takes effect on the next buffer, without
/// a new item.
nonisolated final class SoundTapState: Sendable {
    private let current = Mutex<(setting: SoundSetting, generation: Int)>((.off, 0))

    func set(_ setting: SoundSetting) {
        current.withLock { value in
            guard value.setting != setting else { return }
            value = (setting, value.generation + 1)
        }
    }

    var setting: SoundSetting { current.withLock { $0.setting } }
    fileprivate var snapshot: (setting: SoundSetting, generation: Int) { current.withLock { $0 } }
}

/// What one tap holds: the shared state and the filter built for the
/// stream's format and the setting of one generation.
nonisolated private final class SoundTapContext {
    let state: SoundTapState
    var sampleRate: Double = 0
    var channels = 0
    var interleaved = false
    var isFloat = false
    var generation = -1
    var setting = SoundSetting.off
    var setup: vDSP_biquad_Setup?
    var delays: [[Float]] = []

    init(state: SoundTapState) { self.state = state }

    deinit { if let setup { vDSP_biquad_DestroySetup(setup) } }

    /// Builds the chain again when the setting changed since the last buffer.
    func follow() {
        let now = state.snapshot
        guard now.generation != generation, sampleRate > 0 else { return }
        generation = now.generation
        setting = now.setting
        if let setup { vDSP_biquad_DestroySetup(setup) }
        let preset = SoundPresets.preset(setting.presetID)
        setup = preset.isFlat ? nil
            : vDSP_biquad_CreateSetup(SoundMath.chain(preset, sampleRate: sampleRate), vDSP_Length(preset.bandGainsDB.count))
        delays = Array(repeating: Array(repeating: 0, count: 2 * preset.bandGainsDB.count + 2), count: channels)
    }

    /// One buffer of one channel through the chain, the gain and the limiter.
    func process(_ samples: UnsafeMutablePointer<Float>, count: Int, stride: Int, channel: Int) {
        if let setup, channel < delays.count {
            delays[channel].withUnsafeMutableBufferPointer { delay in
                vDSP_biquad(setup, delay.baseAddress!, samples, vDSP_Stride(stride), samples, vDSP_Stride(stride), vDSP_Length(count))
            }
        }
        let gain = Float(setting.clampedGain)
        for index in 0..<count {
            let position = index * stride
            samples[position] = SoundMath.limited(samples[position] * gain)
        }
    }
}

/// The filter as an `MTAudioProcessingTap` on a player item.
nonisolated enum SoundTap {
    static func make(_ state: SoundTapState) -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(SoundTapContext(state: state)).toOpaque()),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<SoundTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let context = Unmanaged<SoundTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let description = format.pointee
                context.sampleRate = description.mSampleRate
                context.channels = Int(description.mChannelsPerFrame)
                context.isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
                context.interleaved = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
                context.generation = -1
            },
            unprepare: { _ in },
            process: { tap, numberFrames, _, bufferList, numberFramesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferList, flagsOut, nil, numberFramesOut) == noErr else { return }
                let context = Unmanaged<SoundTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                context.follow()
                // An integer format or a setting that does nothing passes as it came.
                guard context.isFloat, !context.setting.isOff else { return }
                let frames = Int(numberFramesOut.pointee)
                let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
                if context.interleaved, let data = buffers.first?.mData {
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for channel in 0..<context.channels {
                        context.process(samples + channel, count: frames, stride: context.channels, channel: channel)
                    }
                } else {
                    for (channel, buffer) in buffers.enumerated() {
                        guard let data = buffer.mData else { continue }
                        context.process(data.assumingMemoryBound(to: Float.self), count: frames, stride: 1, channel: channel)
                    }
                }
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr else { return nil }
        return tap
    }

    /// Hangs the filter on the item's audio track. False when the asset
    /// reports none (a stream converted on the fly) or the tap cannot be
    /// made; the item then plays as it is.
    @MainActor
    static func attach(_ state: SoundTapState, to item: AVPlayerItem) async -> Bool {
        // bearable, because an asset that cannot name its tracks plays
        // without the filter, which is what it would do anyway.
        guard item.audioMix == nil,
              let track = try? await item.asset.loadTracks(withMediaType: .audio).first,
              let tap = make(state) else { return false }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
        return true
    }

    /// The first output of the current route, as the book keys it.
    static func currentRoute() -> SoundRoute? {
        guard let output = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return nil }
        return SoundRoute(portType: output.portType.rawValue, uid: output.uid, name: output.portName)
    }
}
