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
/// and does all DSP outside the lock. The scratch pointer arrays and the
/// "applied parameter" cache are touched only by the render thread.
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
        var buffer: AVAudioPCMBuffer?
        var stretcher: RubberBandStretcher?
    }

    private let lock = OSAllocatedUnfairLock(initialState: Control())

    private let maxChannels = 2
    private let inPtrs: UnsafeMutablePointer<UnsafePointer<Float>?>
    private let outPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>

    // Audio-thread-only caches so we only forward parameter changes to Rubber
    // Band when they actually change.
    private var appliedPitch: Double = .nan
    private var appliedTime: Double = .nan
    private var appliedGeneration: UInt64 = .max

    /// Per-process() input chunk cap and a hard loop bound, so a cold start or
    /// an extreme rate ratio can't spin the render thread unbounded.
    private let maxChunk = 2048
    private let iterationLimit = 32

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
    /// is assumed already primed, so we do NOT request a reset here (that would
    /// discard the priming). A generation bump tells the render thread to
    /// adopt the new objects and re-sync its applied-parameter cache.
    func install(buffer: AVAudioPCMBuffer, stretcher: RubberBandStretcher,
                 regionStart: AVAudioFramePosition, regionEnd: AVAudioFramePosition) {
        lock.withLockUnchecked { c in
            c.buffer = buffer
            c.stretcher = stretcher
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
        lock.withLock { c in
            if playing { c.finished = false }
            c.playing = playing
        }
    }

    func setRegion(start: AVAudioFramePosition, end: AVAudioFramePosition,
                   looping: Bool, seekToStart: Bool) {
        lock.withLock { c in
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
        lock.withLock { $0.looping = looping }
    }

    func seek(to frame: AVAudioFramePosition) {
        lock.withLock { c in
            c.cursor = frame
            c.playhead = frame
            c.resetRequest = true
            c.finished = false
        }
    }

    func setPitchScale(_ scale: Double) { lock.withLock { $0.pitchScale = scale } }
    func setTimeRatio(_ ratio: Double) { lock.withLock { $0.timeRatio = ratio } }

    var playhead: AVAudioFramePosition { lock.withLock { $0.playhead } }
    var isFinished: Bool { lock.withLock { $0.finished } }

    // MARK: - Render (audio thread)

    func render(frameCount: AVAudioFrameCount,
                audioBufferList: UnsafeMutablePointer<AudioBufferList>,
                isSilence: UnsafeMutablePointer<ObjCBool>) -> OSStatus {

        let snap = lock.withLockUnchecked {
            (c: inout Control) -> (playing: Bool, looping: Bool, pitch: Double, time: Double,
                                   regionStart: AVAudioFramePosition, regionEnd: AVAudioFramePosition,
                                   cursor: AVAudioFramePosition, reset: Bool, generation: UInt64,
                                   buffer: AVAudioPCMBuffer?, stretcher: RubberBandStretcher?) in
            let r = c.resetRequest
            c.resetRequest = false
            return (c.playing, c.looping, c.pitchScale, c.timeRatio,
                    c.regionStart, c.regionEnd, c.cursor, r, c.generation,
                    c.buffer, c.stretcher)
        }

        let outABL = UnsafeMutableAudioBufferListPointer(audioBufferList)

        func emitSilence() {
            for buffer in outABL {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            isSilence.pointee = true
        }

        guard snap.playing,
              let buffer = snap.buffer,
              let stretcher = snap.stretcher,
              let srcData = buffer.floatChannelData else {
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

        let bufferFrames = AVAudioFramePosition(buffer.frameLength)
        let regStart = max(0, min(bufferFrames, snap.regionStart))
        let regEnd = max(regStart, min(bufferFrames, snap.regionEnd))
        let srcChannels = Int(buffer.format.channelCount)
        let outChannels = outABL.count
        let useChannels = min(outChannels, srcChannels, maxChannels)

        var cursor = max(regStart, min(regEnd, snap.cursor))
        let frameCountInt = Int(frameCount)
        var reachedEnd = false
        var iterations = 0

        // Feed input until the stretcher can yield a full output slice (or we
        // hit the loop point / end of the non-looping region).
        while stretcher.available < frameCountInt && iterations < iterationLimit {
            iterations += 1
            var framesUntilEnd = regEnd - cursor
            if framesUntilEnd <= 0 {
                if snap.looping {
                    cursor = regStart
                    framesUntilEnd = regEnd - regStart
                    if framesUntilEnd <= 0 { break }   // empty region guard
                } else {
                    for ch in 0..<useChannels { inPtrs[ch] = UnsafePointer(srcData[ch]) }
                    stretcher.process(input: UnsafePointer(inPtrs), sampleCount: 0, final: true)
                    reachedEnd = true
                    break
                }
            }
            let want = stretcher.samplesRequired
            if want <= 0 { break }
            let chunk = min(want, Int(framesUntilEnd), maxChunk)
            for ch in 0..<useChannels {
                inPtrs[ch] = UnsafePointer(srcData[ch].advanced(by: Int(cursor)))
            }
            stretcher.process(input: UnsafePointer(inPtrs), sampleCount: chunk, final: false)
            cursor += AVAudioFramePosition(chunk)
        }

        // Map output channel pointers and pull. Never ask Rubber Band for more
        // than it has available, or its internal RingBuffer logs an over-read.
        for ch in 0..<useChannels {
            outPtrs[ch] = outABL[ch].mData?.assumingMemoryBound(to: Float.self)
        }
        let toRetrieve = min(stretcher.available, frameCountInt)
        var written = 0
        if toRetrieve > 0 {
            written = stretcher.retrieve(output: UnsafePointer(outPtrs), sampleCount: toRetrieve)
        }
        if written < frameCountInt {
            for ch in 0..<useChannels {
                if let p = outPtrs[ch] {
                    p.advanced(by: written).update(repeating: 0, count: frameCountInt - written)
                }
            }
        }
        // Zero any output channels we didn't fill (e.g. mono source into a
        // stereo bus would only fill what useChannels covers).
        if outChannels > useChannels {
            for ch in useChannels..<outChannels {
                if let data = outABL[ch].mData { memset(data, 0, Int(outABL[ch].mDataByteSize)) }
            }
        }
        isSilence.pointee = false

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
