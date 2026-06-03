import AVFoundation
import os

/// Real-time playback core that drives an `AVAudioSourceNode`. It reads decoded
/// PCM from a buffer at a movable cursor, runs it through Rubber Band, and
/// emits the stretched/pitched result. Owning both the read cursor and the
/// stretcher means we feed Rubber Band exactly the input it asks for and pull
/// exactly `frameCount` output — the input:output asymmetry of time stretching
/// no longer fights AVAudioPlayerNode's one-pull-per-slice contract.
///
/// Threading: every value shared between the main thread (UI / transport) and
/// the audio render thread is funnelled through one OSAllocatedUnfairLock. The
/// render thread copies the control snapshot out under a tiny critical section
/// and does all DSP outside the lock. Crucially, the render thread touches NO
/// Objective-C: the buffer's channel pointers / frame count are cached as raw
/// values at install time (the audio IO thread has no autorelease pool, so
/// objc_msgSend that returns autoreleased objects there can trap).
final class PlaybackCore: @unchecked Sendable {

    private struct Control {
        var playing = false
        var looping = false
        var pitchScale: Double = 1.0
        var timeRatio: Double = 1.0
        var regionStart: AVAudioFramePosition = 0
        var regionEnd: AVAudioFramePosition = 0
        var cursor: AVAudioFramePosition = 0
        var playhead: AVAudioFramePosition = 0
        var resetRequest = false
        var finished = false
        var generation: UInt64 = 0
        // Retained for liveness; never messaged from the audio thread.
        var buffer: AVAudioPCMBuffer?
        var stretcher: RubberBandStretcher?
        // Raw channel base pointers + frame count, cached at install.
        var src0: UnsafeMutablePointer<Float>?
        var src1: UnsafeMutablePointer<Float>?
        var srcFrames: AVAudioFramePosition = 0
    }

    // Control holds non-Sendable references, so we use the unchecked lock; the
    // lock itself provides the exclusion guarantee.
    private let lock = OSAllocatedUnfairLock(uncheckedState: Control())

    private let maxChannels = 2
    private let inPtrs: UnsafeMutablePointer<UnsafePointer<Float>?>
    private let outPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>

    // Audio-thread-only caches so we only forward parameter changes to Rubber
    // Band when they actually change.
    private var appliedPitch: Double = .nan
    private var appliedTime: Double = .nan
    private var appliedGeneration: UInt64 = .max

    /// Hard loop bound so a cold start / extreme rate ratio can't spin the
    /// render thread unbounded.
    private let iterationLimit = 64

    init() {
        inPtrs = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: maxChannels)
        outPtrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: maxChannels)
        inPtrs.initialize(repeating: nil, count: maxChannels)
        outPtrs.initialize(repeating: nil, count: maxChannels)
    }

    deinit {
        inPtrs.deallocate()
        outPtrs.deallocate()
    }

    // MARK: - Commands (main thread)

    /// Install a freshly decoded + primed buffer/stretcher pair. The stretcher
    /// is assumed already primed, so we do NOT request a reset (that would
    /// discard the priming). Channel pointers and frame count are read here, on
    /// the main thread, and cached as raw values for the render thread.
    func install(buffer: AVAudioPCMBuffer, stretcher: RubberBandStretcher,
                 regionStart: AVAudioFramePosition, regionEnd: AVAudioFramePosition) {
        let channelData = buffer.floatChannelData
        let channels = Int(buffer.format.channelCount)
        let frames = AVAudioFramePosition(buffer.frameLength)
        let s0 = channelData?[0]
        let s1 = channels > 1 ? channelData?[1] : channelData?[0]

        lock.withLockUnchecked { c in
            c.buffer = buffer
            c.stretcher = stretcher
            c.src0 = s0
            c.src1 = s1
            c.srcFrames = frames
            c.regionStart = regionStart
            c.regionEnd = regionEnd
            c.cursor = regionStart
            c.playhead = regionStart
            c.playing = false
            c.finished = false
            c.resetRequest = false
            c.generation &+= 1
        }
    }

    func setPlaying(_ playing: Bool) {
        lock.withLockUnchecked { c in
            if playing { c.finished = false }
            c.playing = playing
        }
    }

    func setRegion(start: AVAudioFramePosition, end: AVAudioFramePosition,
                   looping: Bool, seekToStart: Bool) {
        lock.withLockUnchecked { c in
            c.regionStart = start
            c.regionEnd = end
            c.looping = looping
            if seekToStart {
                c.cursor = start
                c.playhead = start
                c.resetRequest = true
                c.finished = false
            }
        }
    }

    func setLooping(_ looping: Bool) {
        lock.withLockUnchecked { $0.looping = looping }
    }

    func seek(to frame: AVAudioFramePosition) {
        lock.withLockUnchecked { c in
            c.cursor = frame
            c.playhead = frame
            c.resetRequest = true
            c.finished = false
        }
    }

    func setPitchScale(_ scale: Double) { lock.withLockUnchecked { $0.pitchScale = scale } }
    func setTimeRatio(_ ratio: Double) { lock.withLockUnchecked { $0.timeRatio = ratio } }

    var playhead: AVAudioFramePosition { lock.withLockUnchecked { $0.playhead } }
    var isFinished: Bool { lock.withLockUnchecked { $0.finished } }

    // MARK: - Render (audio thread)

    func render(frameCount: AVAudioFrameCount,
                audioBufferList: UnsafeMutablePointer<AudioBufferList>,
                isSilence: UnsafeMutablePointer<ObjCBool>) -> OSStatus {

        let snap = lock.withLockUnchecked {
            (c: inout Control) -> (playing: Bool, looping: Bool, pitch: Double, time: Double,
                                   regionStart: AVAudioFramePosition, regionEnd: AVAudioFramePosition,
                                   cursor: AVAudioFramePosition, reset: Bool, generation: UInt64,
                                   stretcher: RubberBandStretcher?,
                                   src0: UnsafeMutablePointer<Float>?, src1: UnsafeMutablePointer<Float>?,
                                   srcFrames: AVAudioFramePosition) in
            let r = c.resetRequest
            c.resetRequest = false
            return (c.playing, c.looping, c.pitchScale, c.timeRatio,
                    c.regionStart, c.regionEnd, c.cursor, r, c.generation,
                    c.stretcher, c.src0, c.src1, c.srcFrames)
        }

        let outABL = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let outChannels = outABL.count

        func emitSilence() {
            for buffer in outABL {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            isSilence.pointee = true
        }

        guard snap.playing,
              let stretcher = snap.stretcher,
              let src0 = snap.src0,
              let src1 = snap.src1,
              outChannels > 0 else {
            emitSilence()
            return noErr
        }

        if snap.generation != appliedGeneration {
            appliedGeneration = snap.generation
            // Force re-application of parameters to the newly adopted stretcher.
            // No reset: a just-installed stretcher is already primed.
            appliedPitch = .nan
            appliedTime = .nan
        }
        if snap.reset { stretcher.reset() }
        if snap.pitch != appliedPitch { stretcher.pitchScale = snap.pitch; appliedPitch = snap.pitch }
        if snap.time != appliedTime { stretcher.timeRatio = snap.time; appliedTime = snap.time }

        let regStart = max(0, min(snap.srcFrames, snap.regionStart))
        let regEnd = max(regStart, min(snap.srcFrames, snap.regionEnd))
        let useChannels = min(outChannels, maxChannels)
        let channelBases = (src0, src1)

        var cursor = max(regStart, min(regEnd, snap.cursor))
        let frameCountInt = Int(frameCount)
        var inputExhausted = false
        var iterations = 0

        // Feed input until the stretcher can yield a full output slice, looping
        // at the region end or stopping at the end of a non-looping region.
        while stretcher.available < frameCountInt && iterations < iterationLimit {
            iterations += 1
            var framesUntilEnd = regEnd - cursor
            if framesUntilEnd <= 0 {
                if snap.looping {
                    cursor = regStart
                    framesUntilEnd = regEnd - regStart
                    if framesUntilEnd <= 0 { break }   // empty region guard
                } else {
                    inputExhausted = true
                    break
                }
            }
            let want = stretcher.samplesRequired
            if want <= 0 { break }
            let chunk = min(want, Int(framesUntilEnd))
            if chunk <= 0 { break }
            inPtrs[0] = UnsafePointer(channelBases.0.advanced(by: Int(cursor)))
            inPtrs[1] = UnsafePointer(channelBases.1.advanced(by: Int(cursor)))
            stretcher.process(input: UnsafePointer(inPtrs), sampleCount: chunk, final: false)
            cursor += AVAudioFramePosition(chunk)
        }

        // Map output channel pointers and pull. Never request more than
        // available, or Rubber Band's internal RingBuffer logs an over-read.
        for ch in 0..<useChannels {
            outPtrs[ch] = outABL[ch].mData?.assumingMemoryBound(to: Float.self)
        }
        let toRetrieve = min(stretcher.available, frameCountInt)
        var written = 0
        if toRetrieve > 0 {
            written = stretcher.retrieve(output: UnsafePointer(outPtrs), sampleCount: toRetrieve)
        }
        written = max(0, min(written, frameCountInt))

        if written < frameCountInt {
            for ch in 0..<useChannels {
                if let p = outPtrs[ch] {
                    p.advanced(by: written).update(repeating: 0, count: frameCountInt - written)
                }
            }
        }
        // Zero any output channels we didn't fill.
        if outChannels > useChannels {
            for ch in useChannels..<outChannels {
                if let data = outABL[ch].mData { memset(data, 0, Int(outABL[ch].mDataByteSize)) }
            }
        }
        isSilence.pointee = false

        // We reached the natural end once input is exhausted and the stretcher
        // has no buffered output left to drain.
        let reachedEnd = inputExhausted && stretcher.available <= 0

        lock.withLockUnchecked { c in
            // Only publish if no install/seek happened while we were rendering.
            if c.generation == snap.generation {
                c.cursor = cursor
                c.playhead = cursor
                if reachedEnd {
                    c.playing = false
                    c.finished = true
                }
            }
        }
        return noErr
    }
}
