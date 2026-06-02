import AVFoundation
import Foundation

/// Wraps a non-Sendable value so it can cross a Task boundary. The buffer is
/// produced by a decoder, then immutably read from the main actor; nothing
/// mutates it concurrently, so the manual Sendable conformance is safe.
private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
}

@MainActor
final class AudioEngine {

    enum State: Equatable {
        case idle
        case loaded
        case playing
        case paused
    }

    private(set) var state: State = .idle
    private(set) var sourceURL: URL?
    private(set) var fullBuffer: AVAudioPCMBuffer?
    private(set) var selection: Selection = .whole

    /// Absolute frame from which the currently scheduled slice starts playing.
    /// Used so the playhead position is correct after a seek even before the
    /// player begins consuming samples. Defaults to the selection's start
    /// after a normal play(), is overridden by seek() to the seek target.
    private var scheduledStartFrame: AVAudioFramePosition = 0

    /// Whether new region selections should loop. Toggling while a region is
    /// already active updates that region's loop flag immediately.
    var loopMode: Bool = false {
        didSet {
            guard oldValue != loopMode else { return }
            if case .region(let start, let length, _) = selection {
                setSelection(.region(start: start, length: length, loops: loopMode))
            }
        }
    }

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    /// Placeholder pitch/time node. Will be replaced by a custom AUAudioUnit
    /// wrapping Rubber Band for high-quality stretching beyond ±2 semitones
    /// or ±20% rate. AVAudioUnitTimePitch is fine as a stand-in while wiring UI.
    let pitchTime = AVAudioUnitTimePitch()
    let eq: AVAudioUnitEQ

    static let eqBandFrequencies: [Float] = [
        31, 62, 125, 250, 500,
        1_000, 2_000, 4_000, 8_000, 16_000
    ]

    init() {
        self.eq = AVAudioUnitEQ(numberOfBands: Self.eqBandFrequencies.count)
        configureEQ()
        attachNodes()
    }

    // MARK: - Loading

    func load(url: URL) async throws {
        let box = try await Task.detached(priority: .userInitiated) {
            UncheckedSendable(value: try SFBAudioLoader.decode(url: url))
        }.value
        installBuffer(box.value, url: url)
    }

    private func installBuffer(_ buffer: AVAudioPCMBuffer, url: URL) {
        stop()
        sourceURL = url
        fullBuffer = buffer
        selection = .whole
        scheduledStartFrame = 0
        connectGraph(processingFormat: buffer.format)
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                NSLog("AudioEngine start failed: \(error)")
            }
        }
        state = .loaded
    }

    // MARK: - Transport

    func play() {
        guard fullBuffer != nil else { return }
        if state == .paused {
            player.play()
            state = .playing
            return
        }
        scheduleCurrentSelection()
        player.play()
        state = .playing
    }

    func pause() {
        guard state == .playing else { return }
        player.pause()
        state = .paused
    }

    func stop() {
        player.stop()
        scheduledStartFrame = selectionStartFrame
        state = sourceURL == nil ? .idle : .loaded
    }

    /// Toggle play/pause for the spacebar shortcut.
    func togglePlayPause() {
        switch state {
        case .playing:
            pause()
        case .paused, .loaded:
            play()
        case .idle:
            break
        }
    }

    // MARK: - Selection

    func setSelection(_ selection: Selection) {
        self.selection = selection
        scheduledStartFrame = selectionStartFrame
        switch state {
        case .playing:
            stop()
            play()
        case .paused:
            // The scheduled buffer is now stale; discard it so the next play()
            // reschedules the new selection from its start.
            stop()
        case .loaded, .idle:
            break
        }
    }

    /// Move the playhead to an absolute frame in the file. If the click lands
    /// inside the active region, stay in the loop (seek within); otherwise
    /// clear the region and play from the seek point through the end of file.
    /// Continues playback if it was playing.
    func seek(toFrame frame: AVAudioFramePosition) {
        guard let buffer = fullBuffer else { return }
        let wasPlaying = (state == .playing)
        let total = totalFrames
        let clamped = max(0, min(total, frame))

        var keepLoopRegion: (start: AVAudioFramePosition, length: AVAudioFrameCount)? = nil
        var sliceEnd: AVAudioFramePosition = total

        if case .region(let start, let length, let loops) = selection {
            let regionEnd = start + AVAudioFramePosition(length)
            if clamped >= start && clamped < regionEnd {
                sliceEnd = regionEnd
                if loops { keepLoopRegion = (start, length) }
            } else {
                // Click outside the region: clear it.
                selection = .whole
            }
        }

        player.stop()
        scheduledStartFrame = clamped

        let initialLength = AVAudioFrameCount(sliceEnd - clamped)
        guard initialLength > 0,
              let initialSlice = Self.makeSlice(of: buffer, start: clamped, length: initialLength) else {
            state = .loaded
            return
        }

        let completion: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.handlePlaybackEnded() }
        }

        if let loop = keepLoopRegion {
            // Play the partial seek-to-region-end first, then loop the full region.
            player.scheduleBuffer(initialSlice, at: nil, options: [], completionHandler: nil)
            if let loopSlice = Self.makeSlice(of: buffer, start: loop.start, length: loop.length) {
                player.scheduleBuffer(loopSlice, at: nil, options: [.loops], completionHandler: completion)
            }
        } else {
            player.scheduleBuffer(initialSlice, at: nil, options: [], completionHandler: completion)
        }

        if wasPlaying {
            player.play()
            state = .playing
        } else {
            state = .loaded
        }
    }

    /// Absolute frame offset where the current selection begins.
    var selectionStartFrame: AVAudioFramePosition {
        switch selection {
        case .whole:
            return 0
        case .region(let start, _, _):
            return start
        }
    }

    /// Frame count of the slice currently scheduled (whole file or region).
    var selectionLength: AVAudioFrameCount {
        switch selection {
        case .whole:
            return fullBuffer?.frameLength ?? 0
        case .region(_, let length, _):
            return length
        }
    }

    /// Total frame count of the loaded file.
    var totalFrames: AVAudioFramePosition {
        AVAudioFramePosition(fullBuffer?.frameLength ?? 0)
    }

    /// Absolute playhead position in the original buffer's frame space.
    /// Accounts for: normal play from selection start, seek (scheduledStartFrame
    /// overrides), and looped playback (sampleTime grows monotonically across
    /// loop iterations, so we map it back into the region).
    var currentFramePosition: AVAudioFramePosition {
        guard state == .playing || state == .paused,
              let lastRender = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: lastRender) else {
            return scheduledStartFrame
        }
        let elapsed = max(0, playerTime.sampleTime)
        switch selection {
        case .whole:
            return min(scheduledStartFrame + elapsed, totalFrames)
        case .region(let start, let length, _):
            let lengthFrames = AVAudioFramePosition(length)
            guard lengthFrames > 0 else { return start }
            let regionEnd = start + lengthFrames
            // After a seek-within-region, the first slice plays from
            // scheduledStartFrame to regionEnd (possibly shorter than length).
            // Once that completes, the looping slice [start, regionEnd) takes over.
            let firstIterFrames = max(AVAudioFramePosition(0), regionEnd - scheduledStartFrame)
            if elapsed < firstIterFrames {
                return scheduledStartFrame + elapsed
            } else {
                let afterFirst = elapsed - firstIterFrames
                return start + (afterFirst % lengthFrames)
            }
        }
    }

    /// Audio sample rate, for converting frames to seconds.
    var sampleRate: Double {
        fullBuffer?.format.sampleRate ?? 44_100
    }

    // MARK: - Pitch & time

    var pitchCents: Float {
        get { pitchTime.pitch }
        set { pitchTime.pitch = newValue }
    }

    var rate: Float {
        get { pitchTime.rate }
        set { pitchTime.rate = max(1.0 / 32.0, min(32.0, newValue)) }
    }

    // MARK: - Graph

    private func configureEQ() {
        eq.globalGain = 0
        for (index, freq) in Self.eqBandFrequencies.enumerated() {
            let band = eq.bands[index]
            band.filterType = .parametric
            band.frequency = freq
            band.bandwidth = 1.0
            band.gain = 0
            band.bypass = false
        }
    }

    private func attachNodes() {
        engine.attach(player)
        engine.attach(pitchTime)
        engine.attach(eq)
    }

    private func connectGraph(processingFormat format: AVAudioFormat) {
        let mainMixer = engine.mainMixerNode
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(pitchTime)
        engine.disconnectNodeOutput(eq)

        engine.connect(player, to: pitchTime, format: format)
        engine.connect(pitchTime, to: eq, format: format)
        engine.connect(eq, to: mainMixer, format: format)
    }

    private func scheduleCurrentSelection() {
        guard let buffer = fullBuffer else { return }
        scheduledStartFrame = selectionStartFrame
        let completion: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.handlePlaybackEnded() }
        }
        switch selection {
        case .whole:
            player.scheduleBuffer(buffer,
                                  at: nil,
                                  options: [],
                                  completionHandler: completion)
        case .region(let start, let length, let loops):
            guard let slice = Self.makeSlice(of: buffer, start: start, length: length) else { return }
            let options: AVAudioPlayerNodeBufferOptions = loops ? [.loops] : []
            // .loops keeps the buffer playing forever — completion fires only
            // when interrupted, so we still wire it up for state cleanup.
            player.scheduleBuffer(slice,
                                  at: nil,
                                  options: options,
                                  completionHandler: completion)
        }
    }

    private func handlePlaybackEnded() {
        if state == .playing {
            state = .loaded
        }
    }

    private static func makeSlice(of buffer: AVAudioPCMBuffer,
                                  start: AVAudioFramePosition,
                                  length: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        let total = AVAudioFramePosition(buffer.frameLength)
        let startFrame = max(0, min(total, start))
        let endFrame = min(total, startFrame + AVAudioFramePosition(length))
        let actualLength = AVAudioFrameCount(endFrame - startFrame)
        guard actualLength > 0,
              let slice = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: actualLength) else {
            return nil
        }
        slice.frameLength = actualLength
        let channels = Int(buffer.format.channelCount)
        let frameSize = MemoryLayout<Float>.size
        if let src = buffer.floatChannelData, let dst = slice.floatChannelData {
            for ch in 0..<channels {
                memcpy(dst[ch],
                       src[ch].advanced(by: Int(startFrame)),
                       Int(actualLength) * frameSize)
            }
        }
        return slice
    }
}
