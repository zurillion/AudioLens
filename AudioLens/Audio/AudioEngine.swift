import AVFoundation
import Foundation

@MainActor
final class AudioEngine {

    enum State: Equatable {
        case idle
        case loaded
        case playing
        case paused
    }

    private(set) var state: State = .idle
    private(set) var currentFile: AVAudioFile?
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
        let file = try AVAudioFile(forReading: url)
        installFile(file)
    }

    private func installFile(_ file: AVAudioFile) {
        stop()
        currentFile = file
        selection = .whole
        connectGraph(processingFormat: file.processingFormat)
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
        guard let file = currentFile else { return }
        if state == .paused {
            player.play()
            state = .playing
            return
        }
        scheduleCurrentSelection(in: file)
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
        state = currentFile == nil ? .idle : .loaded
    }

    // MARK: - Selection

    func setSelection(_ selection: Selection) {
        self.selection = selection
        if state == .playing {
            stop()
            play()
        }
    }

    // MARK: - Pitch & time

    /// Pitch offset in cents. Range typically -2400…+2400.
    var pitchCents: Float {
        get { pitchTime.pitch }
        set { pitchTime.pitch = newValue }
    }

    /// Time stretching rate. 1.0 = original, 0.5 = half speed, 2.0 = double.
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

    private func scheduleCurrentSelection(in file: AVAudioFile) {
        switch selection {
        case .whole:
            player.scheduleFile(file, at: nil) { [weak self] in
                Task { @MainActor in self?.handlePlaybackEnded() }
            }
        case .region(let start, let length, let loops):
            schedule(file: file, startFrame: start, frameCount: length, loops: loops)
        }
    }

    private func schedule(file: AVAudioFile,
                          startFrame: AVAudioFramePosition,
                          frameCount: AVAudioFrameCount,
                          loops: Bool) {
        let completion: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if loops, self.state == .playing, let current = self.currentFile {
                    self.schedule(file: current,
                                  startFrame: startFrame,
                                  frameCount: frameCount,
                                  loops: true)
                } else {
                    self.handlePlaybackEnded()
                }
            }
        }
        player.scheduleSegment(file,
                               startingFrame: startFrame,
                               frameCount: frameCount,
                               at: nil,
                               completionHandler: completion)
    }

    private func handlePlaybackEnded() {
        if state == .playing {
            state = .loaded
        }
    }
}
