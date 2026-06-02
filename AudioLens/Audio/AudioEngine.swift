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
        state = sourceURL == nil ? .idle : .loaded
    }

    // MARK: - Selection

    func setSelection(_ selection: Selection) {
        self.selection = selection
        if state == .playing {
            stop()
            play()
        }
    }

    /// Absolute frame offset where the current selection begins. The slice
    /// scheduled on the player counts from zero, so we add this offset to map
    /// the player's sampleTime back to a position in the original buffer.
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
