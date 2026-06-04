import AVFoundation
import os

/// Real-time playback core that drives an `AVAudioSourceNode`. It reads decoded
/// PCM from a buffer at a movable cursor, runs it through Rubber Band, and
/// emits the stretched/pitched result. Owning both the read cursor and the
/// stretcher means we feed Rubber Band exactly the input it asks for and pull
/// exactly `frameCount` output — the input:output asymmetry of time stretching
/// no longer fights AVAudioPlayerNode's one-pull-per-slice contract.
///
/// Output decoupling: Rubber Band emits output in its own block sizes and with
/// processing latency, so a single feed rarely yields exactly `frameCount`
/// frames. The render block accumulates retrieved output into a per-channel
/// scratch buffer and serves `frameCount` from there, feeding/retrieving in a
/// loop until the scratch is full. Retrieving *inside* the loop frees Rubber
/// Band's internal output buffer so it keeps accepting input (otherwise
/// getSamplesRequired() returns 0 and we'd starve → distortion).
///
/// Threading: cross-thread state goes through one OSAllocatedUnfairLock. The
/// render thread snapshots it in a tiny critical section and does all DSP
/// outside the lock. It touches NO Objective-C (the buffer's channel pointers
/// and frame count are cached as raw values at install time — the audio IO
/// thread has no autorelease pool).
final class PlaybackCore: @unchecked Sendable {

    private struct Control {
        var playing = false
        var looping = false
        var pitchScale: Double = 1.0
        var timeRatio: Double = 1.0
        var pan: Double = 0          // -1 = L, 0 = center, +1 = R
        var mono: Bool = false       // sum L+R to mono before panning
        var regionStart: AVAudioFramePosition = 0
        var regionEnd: AVAudioFramePosition = 0
        var cursor: AVAudioFramePosition = 0
        var playhead: AVAudioFramePosition = 0
        var resetRequest = false
        var finished = false
        var generation: UInt64 = 0
        /// Bumped by any main-thread cursor change (seek / region-with-seek /
        /// install). The render publishes its advanced cursor only if this is
        /// unchanged since its snapshot, so a seek that lands mid-render isn't
        /// clobbered by the render's stale cursor write-back.
        var seekEpoch: UInt64 = 0
        var buffer: AVAudioPCMBuffer?           // retained for liveness only
        var stretcher: RubberBandStretcher?
        var src0: UnsafeMutablePointer<Float>?
        var src1: UnsafeMutablePointer<Float>?
        var srcFrames: AVAudioFramePosition = 0
    }

    private let lock = OSAllocatedUnfairLock(uncheckedState: Control())

    private let maxChannels = 2
    private let inPtrs: UnsafeMutablePointer<UnsafePointer<Float>?>
    private let outPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>

    // Per-channel output accumulation scratch (audio-thread-only).
    private let scratchCapacity = 1 << 16
    private let scratch0: UnsafeMutablePointer<Float>
    private let scratch1: UnsafeMutablePointer<Float>
    private var pendingCount = 0
    private var finalSent = false
    /// True while the read cursor sits outside the active region (the region was
    /// dragged across the playhead during play). Used to do a clean stretcher
    /// restart when the cursor comes back into range.
    private var wasOutOfRegion = false

    // Applied-parameter caches (audio-thread-only) to skip redundant calls.
    private var appliedPitch: Double = .nan
    private var appliedTime: Double = .nan
    private var appliedGeneration: UInt64 = .max

    /// Hard loop bound so a cold start / extreme rate can't spin the thread.
    private let iterationLimit = 128

    init() {
        inPtrs = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: maxChannels)
        outPtrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: maxChannels)
        inPtrs.initialize(repeating: nil, count: maxChannels)
        outPtrs.initialize(repeating: nil, count: maxChannels)
        scratch0 = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        scratch1 = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        scratch0.initialize(repeating: 0, count: scratchCapacity)
        scratch1.initialize(repeating: 0, count: scratchCapacity)
    }

    deinit {
        inPtrs.deallocate()
        outPtrs.deallocate()
        scratch0.deallocate()
        scratch1.deallocate()
    }

    // MARK: - Commands (main thread)

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
            c.seekEpoch &+= 1
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
                c.seekEpoch &+= 1
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
            c.seekEpoch &+= 1
        }
    }

    func setPitchScale(_ scale: Double) { lock.withLockUnchecked { $0.pitchScale = scale } }
    func setTimeRatio(_ ratio: Double) { lock.withLockUnchecked { $0.timeRatio = ratio } }
    func setPan(_ pan: Double) { lock.withLockUnchecked { $0.pan = pan } }
    func setMono(_ mono: Bool) { lock.withLockUnchecked { $0.mono = mono } }

    var playhead: AVAudioFramePosition { lock.withLockUnchecked { $0.playhead } }
    var isFinished: Bool { lock.withLockUnchecked { $0.finished } }

    // MARK: - Render (audio thread)

    func render(frameCount: AVAudioFrameCount,
                audioBufferList: UnsafeMutablePointer<AudioBufferList>,
                isSilence: UnsafeMutablePointer<ObjCBool>) -> OSStatus {

        let snap = lock.withLockUnchecked {
            (c: inout Control) -> (playing: Bool, looping: Bool, pitch: Double, time: Double,
                                   pan: Double, mono: Bool,
                                   regionStart: AVAudioFramePosition, regionEnd: AVAudioFramePosition,
                                   cursor: AVAudioFramePosition, reset: Bool, generation: UInt64,
                                   seekEpoch: UInt64,
                                   stretcher: RubberBandStretcher?,
                                   src0: UnsafeMutablePointer<Float>?, src1: UnsafeMutablePointer<Float>?,
                                   srcFrames: AVAudioFramePosition) in
            let r = c.resetRequest
            c.resetRequest = false
            return (c.playing, c.looping, c.pitchScale, c.timeRatio, c.pan, c.mono,
                    c.regionStart, c.regionEnd, c.cursor, r, c.generation, c.seekEpoch,
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
            appliedPitch = .nan
            appliedTime = .nan
            pendingCount = 0     // discard output that belonged to the old file
            finalSent = false
            wasOutOfRegion = false
        }
        if snap.reset {
            stretcher.reset()
            pendingCount = 0
            finalSent = false
        }
        if snap.pitch != appliedPitch { stretcher.pitchScale = snap.pitch; appliedPitch = snap.pitch }
        if snap.time != appliedTime { stretcher.timeRatio = snap.time; appliedTime = snap.time }

        let regStart = max(0, min(snap.srcFrames, snap.regionStart))
        let regEnd = max(regStart, min(snap.srcFrames, snap.regionEnd))
        let useChannels = min(outChannels, maxChannels)
        let frameCountInt = Int(frameCount)

        // The cursor lies strictly outside the region only when the region was
        // dragged across the playhead (a live trim/loop edit) — a natural end
        // leaves the cursor *at* regEnd, not past it. Hold position and emit
        // silence rather than latching "finished", so playback resumes the
        // moment the region grows back over the cursor.
        if snap.cursor < regStart || snap.cursor > regEnd {
            wasOutOfRegion = true
            pendingCount = 0
            emitSilence()
            return noErr
        }
        if wasOutOfRegion {
            // Back in range: restart the stretcher cleanly from the cursor.
            stretcher.reset()
            pendingCount = 0
            finalSent = false
            wasOutOfRegion = false
        }

        var cursor = max(regStart, min(regEnd, snap.cursor))
        var inputDone = false
        var iterations = 0

        // Fill the scratch up to one render slice, feeding Rubber Band and
        // draining its output each iteration.
        while pendingCount < frameCountInt && iterations < iterationLimit {
            iterations += 1

            if !inputDone {
                var framesUntilEnd = regEnd - cursor
                if framesUntilEnd <= 0 {
                    if snap.looping {
                        cursor = regStart
                        framesUntilEnd = regEnd - regStart
                        if framesUntilEnd <= 0 { inputDone = true }   // empty region
                    } else {
                        inputDone = true
                    }
                }
                if !inputDone {
                    let want = stretcher.samplesRequired
                    if want > 0 {
                        let chunk = min(want, Int(framesUntilEnd))
                        if chunk > 0 {
                            inPtrs[0] = UnsafePointer(src0.advanced(by: Int(cursor)))
                            inPtrs[1] = UnsafePointer(src1.advanced(by: Int(cursor)))
                            stretcher.process(input: UnsafePointer(inPtrs),
                                              sampleCount: chunk, final: false)
                            cursor += AVAudioFramePosition(chunk)
                        }
                    }
                }
            }

            // For a non-looping region at its end, tell Rubber Band there's no
            // more input so it flushes its latency tail. Send it once.
            if inputDone && !finalSent {
                inPtrs[0] = UnsafePointer(src0)
                inPtrs[1] = UnsafePointer(src1)
                stretcher.process(input: UnsafePointer(inPtrs), sampleCount: 0, final: true)
                finalSent = true
            }

            // Drain available output into the scratch.
            let avail = stretcher.available
            if avail > 0 {
                let space = scratchCapacity - pendingCount
                let pull = min(avail, space)
                if pull > 0 {
                    outPtrs[0] = scratch0.advanced(by: pendingCount)
                    outPtrs[1] = scratch1.advanced(by: pendingCount)
                    let got = stretcher.retrieve(output: UnsafePointer(outPtrs), sampleCount: pull)
                    if got > 0 {
                        pendingCount += got
                    } else if inputDone {
                        break
                    }
                } else {
                    break   // scratch full (shouldn't happen: capacity > frameCount)
                }
            } else if inputDone {
                break       // input finished and nothing left to drain
            } else {
                break       // transient starvation; recover next render
            }
        }

        // Serve frameCount frames from the front of the scratch.
        for ch in 0..<useChannels {
            outPtrs[ch] = outABL[ch].mData?.assumingMemoryBound(to: Float.self)
        }
        let dst0 = outPtrs[0]
        let dst1 = useChannels > 1 ? outPtrs[1] : nil
        let outCount = min(pendingCount, frameCountInt)
        if outCount > 0 {
            writeServed(dst0: dst0, dst1: dst1, count: outCount, pan: snap.pan, mono: snap.mono)
        }
        if outCount < frameCountInt {
            dst0?.advanced(by: outCount).update(repeating: 0, count: frameCountInt - outCount)
            dst1?.advanced(by: outCount).update(repeating: 0, count: frameCountInt - outCount)
        }
        // Shift the unused remainder to the front of the scratch.
        let remaining = pendingCount - outCount
        if remaining > 0 {
            memmove(scratch0, scratch0.advanced(by: outCount), remaining * MemoryLayout<Float>.size)
            memmove(scratch1, scratch1.advanced(by: outCount), remaining * MemoryLayout<Float>.size)
        }
        pendingCount = remaining

        if outChannels > useChannels {
            for ch in useChannels..<outChannels {
                if let data = outABL[ch].mData { memset(data, 0, Int(outABL[ch].mDataByteSize)) }
            }
        }
        isSilence.pointee = false

        let reachedEnd = inputDone && pendingCount == 0 && stretcher.available <= 0

        lock.withLockUnchecked { c in
            // Skip the write-back if a buffer reinstall or a seek happened while
            // we were rendering — otherwise we'd clobber the new cursor with our
            // stale, locally-advanced one (the "seek has no effect during play"
            // bug).
            if c.generation == snap.generation && c.seekEpoch == snap.seekEpoch {
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

    /// Copy `count` frames from the scratch into the output, applying mono
    /// summing and/or pan. Gains depend only on the snapshot, so they're
    /// computed once per render — the per-sample loop is pure arithmetic.
    private func writeServed(dst0: UnsafeMutablePointer<Float>?,
                             dst1: UnsafeMutablePointer<Float>?,
                             count: Int, pan: Double, mono: Bool) {
        let s0 = scratch0, s1 = scratch1
        if let d0 = dst0, let d1 = dst1 {
            if mono {
                // Sum to mono, then equal-power pan: constant total power as the
                // image moves, ~0.707 per side at center.
                let angle = (pan + 1.0) * 0.25 * Double.pi   // [-1,1] → [0, π/2]
                let lg = Float(cos(angle)), rg = Float(sin(angle))
                for i in 0..<count {
                    let m = 0.5 * (s0[i] + s1[i])
                    d0[i] = m * lg
                    d1[i] = m * rg
                }
            } else if pan != 0 {
                // Stereo balance: attenuate the channel away from the pan side.
                let lg: Float = pan <= 0 ? 1 : Float(1.0 - pan)
                let rg: Float = pan >= 0 ? 1 : Float(1.0 + pan)
                for i in 0..<count {
                    d0[i] = s0[i] * lg
                    d1[i] = s1[i] * rg
                }
            } else {
                d0.update(from: s0, count: count)
                d1.update(from: s1, count: count)
            }
        } else if let d0 = dst0 {
            // Mono output device.
            if mono {
                for i in 0..<count { d0[i] = 0.5 * (s0[i] + s1[i]) }
            } else {
                d0.update(from: s0, count: count)
            }
        }
    }
}
