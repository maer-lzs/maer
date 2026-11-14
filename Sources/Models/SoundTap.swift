// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Accelerate
import AVFoundation
import MediaToolbox
import Synchronization

/// The filter for one stream format and one setting: the vDSP setup, the
/// delay memory of every channel and the gain, all made off the audio
/// thread. The audio thread only runs it.
nonisolated final class SoundChain {
    let isOff: Bool
    let gain: Float
    let channels: Int
    let delaysPerChannel: Int
    private let setup: vDSP_biquad_Setup?
    let delays: UnsafeMutablePointer<Float>

    init(setting: SoundSetting, sampleRate: Double, channels: Int) {
        let preset = SoundPresets.preset(setting.presetID)
        isOff = setting.isOff
        gain = Float(setting.clampedGain)
        self.channels = channels
        delaysPerChannel = 2 * preset.bandGainsDB.count + 2
        setup = preset.isFlat || sampleRate <= 0 ? nil
            : vDSP_biquad_CreateSetup(SoundMath.chain(preset, sampleRate: sampleRate), vDSP_Length(preset.bandGainsDB.count))
        let count = max(channels, 1) * delaysPerChannel
        delays = .allocate(capacity: count)
        delays.initialize(repeating: 0, count: count)
    }

    deinit {
        if let setup { vDSP_biquad_DestroySetup(setup) }
        delays.deallocate()
    }

    /// Takes over the filter memory of the chain before, when both have the
    /// same shape, so a change of setting does not start from silence and
    /// click. Copies, allocates nothing.
    func continueFrom(_ before: SoundChain) {
        guard before.channels == channels, before.delaysPerChannel == delaysPerChannel else { return }
        delays.update(from: before.delays, count: channels * delaysPerChannel)
    }

    /// One buffer of one channel through the bands, the gain and the limiter.
    func process(_ samples: UnsafeMutablePointer<Float>, count: Int, stride: Int, channel: Int) {
        guard !isOff, channel < channels else { return }
        if let setup {
            vDSP_biquad(setup, delays + channel * delaysPerChannel, samples, vDSP_Stride(stride),
                        samples, vDSP_Stride(stride), vDSP_Length(count))
        }
        for index in 0..<count {
            let position = index * stride
            samples[position] = SoundMath.limited(samples[position] * gain)
        }
    }
}

/// Where one tap finds its chain: the stream's format, and the chain as a
/// pointer the audio thread reads without a lock.
nonisolated final class SoundSlot: Sendable {
    let sampleRate: Double
    let channels: Int
    /// The chain's address; 0 is none. An address, because a pointer is not Sendable.
    private let address = Atomic<UInt>(0)

    init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// The chain now, without a lock.
    func load() -> UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: address.load(ordering: .acquiring))
    }

    /// Hands a chain over and returns the one before.
    func exchange(_ chain: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: address.exchange(UInt(bitPattern: chain), ordering: .acquiringAndReleasing))
    }
}

/// The setting the filter plays with now, shared between the player and
/// the taps. A new setting builds a chain for every tap here, off the
/// audio thread, and hands it over; a chain handed over is kept a while
/// before it is freed, so the audio thread never frees one.
nonisolated final class SoundTapState: Sendable {
    private struct Book {
        var setting = SoundSetting.off
        var generation = 0
        var builds = 0
        var slots: [ObjectIdentifier: SoundSlot] = [:]
        var retired: [(chain: UnsafeMutableRawPointer, at: UInt64)] = []
    }
    private let book = Mutex(Book())
    /// How long a chain handed over stays alive: far longer than a buffer.
    static let retireAfterNanos: UInt64 = 2_000_000_000

    var setting: SoundSetting { book.withLock { $0.setting } }
    /// Counts the settings that differed from the one before.
    var generation: Int { book.withLock { $0.generation } }
    /// Counts the chains built, for every tap and every new setting.
    var builds: Int { book.withLock { $0.builds } }

    func set(_ setting: SoundSetting) {
        let freed: [UnsafeMutableRawPointer] = book.withLock { book in
            guard book.setting != setting else { return [] }
            book.setting = setting
            book.generation += 1
            let now = DispatchTime.now().uptimeNanoseconds
            for slot in book.slots.values {
                let fresh = Unmanaged.passRetained(SoundChain(setting: setting, sampleRate: slot.sampleRate, channels: slot.channels))
                book.builds += 1
                if let old = slot.exchange(fresh.toOpaque()) {
                    book.retired.append((old, now))
                }
            }
            return Self.takeExpired(&book, now: now)
        }
        for chain in freed { Unmanaged<SoundChain>.fromOpaque(chain).release() }
    }

    /// A tap that knows its format joins: its chain for the setting now.
    func register(_ slot: SoundSlot) {
        book.withLock { book in
            let fresh = Unmanaged.passRetained(SoundChain(setting: book.setting, sampleRate: slot.sampleRate, channels: slot.channels))
            book.builds += 1
            if let old = slot.exchange(fresh.toOpaque()) {
                book.retired.append((old, DispatchTime.now().uptimeNanoseconds))
            }
            book.slots[ObjectIdentifier(slot)] = slot
        }
    }

    /// A tap that stops leaves; its chain retires like a replaced one.
    func unregister(_ slot: SoundSlot) {
        book.withLock { book in
            book.slots.removeValue(forKey: ObjectIdentifier(slot))
            if let old = slot.exchange(nil) {
                book.retired.append((old, DispatchTime.now().uptimeNanoseconds))
            }
        }
    }

    private static func takeExpired(_ book: inout Book, now: UInt64) -> [UnsafeMutableRawPointer] {
        let expired = book.retired.filter { now - $0.at > retireAfterNanos }.map(\.chain)
        book.retired.removeAll { now - $0.at > retireAfterNanos }
        return expired
    }
}

/// What one tap holds: the shared state, its slot once the format is known,
/// and the chain it last ran.
nonisolated private final class SoundTapContext {
    let state: SoundTapState
    var slot: SoundSlot?
    var interleaved = false
    var isFloat = false
    var current: UnsafeMutableRawPointer?

    init(state: SoundTapState) { self.state = state }
}

/// The filter as an `MTAudioProcessingTap` on a player item.
nonisolated enum SoundTap {
    /// Why a filter hangs on an item or does not.
    enum Attached: String {
        case hung = "hung"
        case alreadyHung = "not hung, the item carries a mix already"
        case noAudioTrack = "not reachable, the item reports no audio track"
        case tapNotMade = "not hung, the tap could not be made"
    }

    static func make(_ state: SoundTapState) -> MTAudioProcessingTap? {
        let context = Unmanaged.passRetained(SoundTapContext(state: state)).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: context,
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<SoundTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                // Not the audio thread's buffer loop: the chain is built here once per format.
                let context = Unmanaged<SoundTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let description = format.pointee
                context.isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
                context.interleaved = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
                let slot = SoundSlot(sampleRate: description.mSampleRate, channels: Int(description.mChannelsPerFrame))
                context.slot = slot
                context.current = nil
                context.state.register(slot)
            },
            unprepare: { tap in
                let context = Unmanaged<SoundTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                if let slot = context.slot { context.state.unregister(slot) }
                context.slot = nil
                context.current = nil
            },
            process: { tap, numberFrames, _, bufferList, numberFramesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferList, flagsOut, nil, numberFramesOut) == noErr else { return }
                let context = Unmanaged<SoundTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                // An integer format passes as it came; the chain is read without a lock.
                guard context.isFloat, let raw = context.slot?.load() else { return }
                let chain = Unmanaged<SoundChain>.fromOpaque(raw)
                if raw != context.current {
                    if let before = context.current {
                        chain._withUnsafeGuaranteedRef { fresh in
                            Unmanaged<SoundChain>.fromOpaque(before)._withUnsafeGuaranteedRef { fresh.continueFrom($0) }
                        }
                    }
                    context.current = raw
                }
                let frames = Int(numberFramesOut.pointee)
                let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
                chain._withUnsafeGuaranteedRef { chain in
                    if context.interleaved, let data = buffers.first?.mData {
                        let samples = data.assumingMemoryBound(to: Float.self)
                        for channel in 0..<chain.channels {
                            chain.process(samples + channel, count: frames, stride: chain.channels, channel: channel)
                        }
                    } else {
                        for (channel, buffer) in buffers.enumerated() {
                            guard let data = buffer.mData else { continue }
                            chain.process(data.assumingMemoryBound(to: Float.self), count: frames, stride: 1, channel: channel)
                        }
                    }
                }
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr else {
            // The tap was not made, so its finalize never runs: the context goes here.
            Unmanaged<SoundTapContext>.fromOpaque(context).release()
            return nil
        }
        return tap
    }

    /// Hangs the filter on the item's audio track, and says why when it
    /// does not: the item carries a mix already (asked again after the
    /// tracks are read), it reports no audio track (a stream converted on
    /// the fly), or the tap cannot be made.
    @MainActor
    static func attach(_ state: SoundTapState, to item: AVPlayerItem) async -> Attached {
        guard item.audioMix == nil else { return .alreadyHung }
        // bearable, because an asset that cannot name its tracks plays
        // without the filter, which is what it would do anyway.
        guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return .noAudioTrack }
        guard item.audioMix == nil else { return .alreadyHung }
        guard let tap = make(state) else { return .tapNotMade }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
        return .hung
    }

    /// The first output of the current route, as the book keys it.
    static func currentRoute() -> SoundRoute? {
        guard let output = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return nil }
        return SoundRoute(portType: output.portType.rawValue, uid: output.uid, name: output.portName)
    }
}
