import AVFoundation
import CRubberBand

/// Custom AUAudioUnit that wraps RubberBandStretcher for real-time pitch
/// shifting and time stretching, using Rubber Band's R3 ("Finer") engine.
///
/// Drop-in replacement for AVAudioUnitTimePitch in AVAudioEngine — connect
/// it via AVAudioUnit returned by `instantiate()`.
///
/// Format: float32 non-interleaved stereo. AudioEngine's pipeline already
/// normalises decoded buffers to that layout, so the bus format always
/// matches.
///
/// Real-time safety: the render block doesn't allocate. Scratch buffers and
/// pointer arrays are pre-allocated in `allocateRenderResources()`. Parameter
/// updates (pitch / rate) cross from the main actor to the audio thread as
/// single-word Double writes; the staleness window is at most one render
/// quantum and is benign for slider-driven changes.
final class RubberBandAudioUnit: AUAudioUnit {

    // MARK: - Component identity

    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x52426E64,           // 'RBnd'
        componentManufacturer: 0x416C6E73,       // 'Alns'
        componentFlags: 0,
        componentFlagsMask: 0
    )

    /// Call before instantiating via AVAudioUnit.instantiate(with:). Lazy
    /// static initialisation guarantees the registration runs exactly once
    /// across all callers without needing a mutable flag.
    static let registerOnce: Void = {
        AUAudioUnit.registerSubclass(
            RubberBandAudioUnit.self,
            as: componentDescription,
            name: "AudioLens Rubber Band",
            version: 0x00010000
        )
    }()

    // MARK: - State

    private let processingFormat: AVAudioFormat
    private let channelCount: Int
    private let maxPullFrames: AVAudioFrameCount = 4096

    private var stretcher: RubberBandStretcher?
    private var _inputBusses: AUAudioUnitBusArray!
    private var _outputBusses: AUAudioUnitBusArray!

    // Scratch storage. Allocated once and reused by the render block.
    private var inputChannelPtrs: UnsafeMutablePointer<UnsafePointer<Float>?>?
    private var outputChannelPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?
    private var inputScratch: [UnsafeMutablePointer<Float>] = []
    private var inputBufferList: UnsafeMutableAudioBufferListPointer?

    // Parameter staging. Audio thread reads, main thread writes. Writes are
    // single-word atomic on 64-bit; brief tearing of the snapshot is harmless
    // for these slowly-changing values.
    private var pendingPitchScale: Double = 1.0
    private var pendingTimeRatio: Double = 1.0
    private var appliedPitchScale: Double = 1.0
    private var appliedTimeRatio: Double = 1.0

    // MARK: - Init

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        // We accept any sample rate at instantiation time; the actual rate is
        // read from the bus format in allocateRenderResources().
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_ParamError))
        }
        self.processingFormat = format
        self.channelCount = Int(format.channelCount)

        try super.init(componentDescription: componentDescription, options: options)

        let inputBus = try AUAudioUnitBus(format: format)
        let outputBus = try AUAudioUnitBus(format: format)
        self._inputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        self._outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        self.maximumFramesToRender = maxPullFrames
    }

    deinit {
        freeScratch()
    }

    // MARK: - Bus arrays

    override var inputBusses: AUAudioUnitBusArray { _inputBusses }
    override var outputBusses: AUAudioUnitBusArray { _outputBusses }

    override var latency: TimeInterval {
        guard let stretcher else { return 0 }
        return Double(stretcher.startDelay) / outputBusses[0].format.sampleRate
    }

    // MARK: - Parameters (main thread)

    /// Pitch offset in cents. ±1200 = ±1 octave.
    var pitchCents: Double {
        get { 1200.0 * log2(pendingPitchScale) }
        set { pendingPitchScale = pow(2.0, newValue / 1200.0) }
    }

    /// Playback rate: 1.0 = original, 2.0 = double speed, 0.5 = half speed.
    /// Rubber Band's time ratio is the reciprocal (output duration / input
    /// duration), so rate = 1 / timeRatio.
    var rate: Double {
        get { 1.0 / max(.leastNormalMagnitude, pendingTimeRatio) }
        set { pendingTimeRatio = 1.0 / max(0.001, newValue) }
    }

    // MARK: - Allocate / deallocate render resources

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()

        let format = outputBusses[0].format
        guard format.channelCount == channelCount,
              format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved else {
            throw NSError(domain: NSOSStatusErrorDomain,
                          code: Int(kAudioUnitErr_FormatNotSupported))
        }

        // (Re)create the stretcher for this sample rate.
        let s = RubberBandStretcher(sampleRate: format.sampleRate, channels: channelCount)
        s.pitchScale = pendingPitchScale
        s.timeRatio = pendingTimeRatio
        appliedPitchScale = pendingPitchScale
        appliedTimeRatio = pendingTimeRatio
        stretcher = s

        allocateScratch()
    }

    override func deallocateRenderResources() {
        super.deallocateRenderResources()
        stretcher = nil
        freeScratch()
    }

    private func allocateScratch() {
        freeScratch()

        let inP = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: channelCount)
        let outP = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: channelCount)
        inputChannelPtrs = inP
        outputChannelPtrs = outP

        // Scratch float buffers for pulled input.
        var bufs: [UnsafeMutablePointer<Float>] = []
        bufs.reserveCapacity(channelCount)
        for _ in 0..<channelCount {
            let buf = UnsafeMutablePointer<Float>.allocate(capacity: Int(maxPullFrames))
            buf.initialize(repeating: 0, count: Int(maxPullFrames))
            bufs.append(buf)
        }
        inputScratch = bufs

        // Pre-built AudioBufferList that points to the scratch buffers; the
        // render block hands this to the pullInputBlock.
        let abl = AudioBufferList.allocate(maximumBuffers: channelCount)
        for ch in 0..<channelCount {
            abl[ch] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(maxPullFrames) * UInt32(MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(bufs[ch])
            )
        }
        inputBufferList = abl
    }

    private func freeScratch() {
        inputChannelPtrs?.deallocate(); inputChannelPtrs = nil
        outputChannelPtrs?.deallocate(); outputChannelPtrs = nil
        for ptr in inputScratch { ptr.deallocate() }
        inputScratch.removeAll()
        if let abl = inputBufferList {
            free(abl.unsafeMutablePointer)
            inputBufferList = nil
        }
    }

    // MARK: - Render

    override var internalRenderBlock: AUInternalRenderBlock {
        let channelCount = self.channelCount
        return { [unowned self]
            actionFlags, timestamp, frameCount, outputBusNumber, outputData, _, pullInputBlock in

            guard let stretcher = self.stretcher,
                  let pullInput = pullInputBlock,
                  let inputCPtrs = self.inputChannelPtrs,
                  let outputCPtrs = self.outputChannelPtrs,
                  let inputABL = self.inputBufferList else {
                return kAudioUnitErr_NoConnection
            }

            // Apply pending parameter changes lazily. Avoids redundant calls
            // into Rubber Band when nothing changed.
            let p = self.pendingPitchScale
            if p != self.appliedPitchScale {
                stretcher.pitchScale = p
                self.appliedPitchScale = p
            }
            let r = self.pendingTimeRatio
            if r != self.appliedTimeRatio {
                stretcher.timeRatio = r
                self.appliedTimeRatio = r
            }

            // Pump the stretcher until it has enough output, pulling more
            // input from upstream as Rubber Band asks for it.
            while stretcher.available < Int(frameCount) {
                let needed = max(1, stretcher.samplesRequired)
                let pullFrames = AUAudioFrameCount(min(needed, Int(self.maxPullFrames)))

                // Reset the scratch ABL for this pull.
                for ch in 0..<channelCount {
                    inputABL[ch].mDataByteSize =
                        UInt32(pullFrames) * UInt32(MemoryLayout<Float>.size)
                }
                var pullFlags = AudioUnitRenderActionFlags(rawValue: 0)
                let pullStatus = pullInput(
                    &pullFlags,
                    timestamp,
                    pullFrames,
                    0,
                    inputABL.unsafeMutablePointer
                )
                if pullStatus != noErr { return pullStatus }

                // Hand per-channel pointers to Rubber Band.
                for ch in 0..<channelCount {
                    if let raw = inputABL[ch].mData {
                        inputCPtrs[ch] = UnsafePointer(raw.assumingMemoryBound(to: Float.self))
                    } else {
                        inputCPtrs[ch] = nil
                    }
                }
                stretcher.process(input: inputCPtrs,
                                  sampleCount: Int(pullFrames),
                                  final: false)
            }

            // Map output ABL to per-channel pointers and pull from Rubber Band.
            let outABL = UnsafeMutableAudioBufferListPointer(outputData)
            for ch in 0..<channelCount {
                if let raw = outABL[ch].mData {
                    outputCPtrs[ch] = raw.assumingMemoryBound(to: Float.self)
                } else {
                    outputCPtrs[ch] = nil
                }
            }
            let written = stretcher.retrieve(output: outputCPtrs, sampleCount: Int(frameCount))

            // Zero any tail Rubber Band couldn't fill (shouldn't happen in
            // steady state after the pump above, but defensively safe).
            if written < Int(frameCount) {
                for ch in 0..<channelCount {
                    if let ptr = outputCPtrs[ch] {
                        let tail = Int(frameCount) - written
                        ptr.advanced(by: written).update(repeating: 0, count: tail)
                    }
                }
            }
            return noErr
        }
    }
}
