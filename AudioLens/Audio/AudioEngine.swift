import AVFoundation
import Foundation

/// Wraps a non-Sendable value so it can cross a Task boundary. Produced by the
/// decode task and consumed once on the main actor; nothing mutates it
/// concurrently, so the manual Sendable conformance is safe.
private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
}

/// Main-actor controller over the real-time PlaybackCore. Translates UI intent
/// (load / play / pause / seek / select / loop / pitch / rate / volume) into
/// thread-safe commands on the core, which drives an AVAudioSourceNode through
/// Rubber Band and then the graphic EQ.
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

    /// Whether new region selections should loop. Defaults to true: selecting a
    /// region is overwhelmingly a "loop this section to practice it" action.
    var loopMode: Bool = true {
        didSet {
            guard oldValue != loopMode else { return }
            if case .region(let start, let length, _) = selection {
                selection = .region(start: start, length: length, loops: loopMode)
                core.setLooping(loopMode)
            }
        }
    }

    let engine = AVAudioEngine()
    let eq: AVAudioUnitEQ
    private let core = PlaybackCore()
    private var sourceNode: AVAudioSourceNode?

    // Pitch / time held as Rubber Band's native quantities so we can hand them
    // to a freshly created stretcher before priming (avoids a transient).
    private var currentPitchScale: Double = 1.0
    private var currentTimeRatio: Double = 1.0

    /// The graphic EQ is created once with the maximum band count; selecting a
    /// smaller count activates the first N bands and bypasses the rest, so we
    /// never have to rewire the running graph.
    static let supportedEQBandCounts = [10, 20, 30]
    private static let maxEQBands = 30
    private(set) var eqBandCount = 10
    private(set) var eqFrequencies: [Float] = []

    init() {
        self.eq = AVAudioUnitEQ(numberOfBands: Self.maxEQBands)
        eq.globalGain = 0
        setEQBandCount(10)
        engine.attach(eq)
    }

    // MARK: - Graphic EQ

    /// Center frequencies for an `n`-band graphic EQ, log-spaced from 31.5 Hz to
    /// 16 kHz (≈ octave spacing at 10 bands, ≈ 1/3-octave at 30).
    static func eqFrequencies(forBandCount n: Int) -> [Float] {
        let low = 31.5, high = 16_000.0
        guard n > 1 else { return [1_000] }
        return (0..<n).map { i in
            Float(low * pow(high / low, Double(i) / Double(n - 1)))
        }
    }

    func setEQBandCount(_ count: Int) {
        let n = min(Self.maxEQBands, max(1, count))
        eqBandCount = n
        let freqs = Self.eqFrequencies(forBandCount: n)
        eqFrequencies = freqs

        let totalOctaves = log2(16_000.0 / 31.5)
        let bandwidth = Float(max(0.05, min(5.0, totalOctaves / Double(max(1, n - 1)))))

        for i in 0..<Self.maxEQBands {
            let band = eq.bands[i]
            if i < n {
                band.filterType = .parametric
                band.frequency = freqs[i]
                band.bandwidth = bandwidth
                band.gain = 0
                band.bypass = false
            } else {
                band.gain = 0
                band.bypass = true
            }
        }
    }

    /// Flatten all active bands.
    func resetEQ() {
        for i in 0..<eqBandCount {
            eq.bands[i].gain = 0
        }
    }

    // MARK: - Loading

    func load(url: URL) async throws {
        let pitchScale = currentPitchScale
        let timeRatio = currentTimeRatio
        let box = try await Task.detached(priority: .userInitiated) {
            // SFBAudioLoader already returns float32 non-interleaved stereo at a
            // standard sample rate, so no further normalisation is needed.
            let buffer = try SFBAudioLoader.decode(url: url)
            let stretcher = RubberBandStretcher(sampleRate: buffer.format.sampleRate,
                                                channels: Int(buffer.format.channelCount))
            stretcher.pitchScale = pitchScale
            stretcher.timeRatio = timeRatio
            stretcher.prime()
            return UncheckedSendable(value: (buffer, stretcher))
        }.value
        install(buffer: box.value.0, stretcher: box.value.1, url: url)
    }

    private func install(buffer: AVAudioPCMBuffer, stretcher: RubberBandStretcher, url: URL) {
        sourceURL = url
        fullBuffer = buffer
        selection = .whole
        bookmarks = []
        onBookmarksChanged?()
        rebuildGraph(format: buffer.format)
        core.install(buffer: buffer,
                     stretcher: stretcher,
                     regionStart: 0,
                     regionEnd: AVAudioFramePosition(buffer.frameLength))
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
        if core.isFinished {
            // Restart the selection from its beginning after a natural end.
            core.seek(to: selectionStartFrame)
        }
        core.setPlaying(true)
        state = .playing
    }

    func pause() {
        guard state == .playing else { return }
        core.setPlaying(false)
        state = .paused
    }

    func stop() {
        core.setPlaying(false)
        core.seek(to: selectionStartFrame)
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

    /// Reconcile main-actor state with the core after a natural end-of-playback
    /// (the render thread flips the core to finished). Called from the UI's
    /// playhead timer.
    func reconcile() {
        if state == .playing && core.isFinished {
            state = .loaded
        }
    }

    // MARK: - Selection & seeking

    func setSelection(_ selection: Selection) {
        self.selection = selection
        applyRegionToCore(seekToStart: true)
    }

    /// Move the playhead to an absolute frame. A click inside the active region
    /// stays within it (the loop continues); a click outside clears the region
    /// and plays the whole file from there. Playback state is preserved.
    func seek(toFrame frame: AVAudioFramePosition) {
        guard fullBuffer != nil else { return }
        let clamped = max(0, min(totalFrames, frame))
        if case .region(let start, let length, _) = selection {
            let regionEnd = start + AVAudioFramePosition(length)
            if !(clamped >= start && clamped < regionEnd) {
                selection = .whole
            }
        }
        applyRegionToCore(seekToStart: false)
        core.seek(to: clamped)
    }

    /// Move to the start of the current playback context (region start, or file
    /// start when there's no region). Preserves playing/paused state.
    func seekToStart() {
        seek(toFrame: selectionStartFrame)
    }

    /// Nudge the playhead by `seconds` (negative = backward). A looping region
    /// wraps modulo its length; otherwise the target is clamped one frame short
    /// of the exclusive end so seek()'s "inside region" test still passes.
    func seekRelative(seconds: Double) {
        let delta = AVAudioFramePosition(seconds * sampleRate)
        let target = currentFramePosition + delta
        let lowerBound = selectionStartFrame
        let upperBoundExclusive: AVAudioFramePosition
        let wrap: Bool
        switch selection {
        case .whole:
            upperBoundExclusive = totalFrames
            wrap = false
        case .region(let start, let length, let loops):
            upperBoundExclusive = start + AVAudioFramePosition(length)
            wrap = loops
        }
        let span = upperBoundExclusive - lowerBound
        if wrap, span > 0 {
            var offset = (target - lowerBound) % span
            if offset < 0 { offset += span }
            seek(toFrame: lowerBound + offset)
        } else {
            let upperBound = max(lowerBound, upperBoundExclusive - 1)
            seek(toFrame: max(lowerBound, min(upperBound, target)))
        }
    }

    /// Set the loop region's edges directly (e.g. dragging the loop handles),
    /// without moving the playhead. Updates the live loop bounds; if the cursor
    /// ends up outside, the render clamps it next slice.
    func setRegionBounds(start: AVAudioFramePosition, end: AVAudioFramePosition) {
        guard fullBuffer != nil else { return }
        let lo = max(0, min(totalFrames, min(start, end)))
        let hi = max(lo + 1, min(totalFrames, max(start, end)))
        selection = .region(start: lo, length: AVAudioFrameCount(hi - lo), loops: loopMode)
        core.setRegion(start: lo, end: hi, looping: loopMode, seekToStart: false)
    }

    // MARK: - Bookmarks

    /// Bookmark positions in source-buffer frames, kept sorted ascending.
    /// In-memory and per loaded file (cleared on load).
    private(set) var bookmarks: [AVAudioFramePosition] = []

    /// Invoked on the main actor whenever the bookmark set changes, so the
    /// menu and waveform can refresh.
    var onBookmarksChanged: (() -> Void)?

    private var bookmarkTolerance: AVAudioFramePosition {
        max(1, AVAudioFramePosition(sampleRate * 0.05))   // 50 ms
    }

    func addBookmarkAtPlayhead() {
        addBookmark(at: currentFramePosition)
    }

    func addBookmark(at frame: AVAudioFramePosition) {
        guard fullBuffer != nil else { return }
        let clamped = max(0, min(totalFrames, frame))
        if bookmarks.contains(where: { abs($0 - clamped) < bookmarkTolerance }) { return }
        bookmarks.append(clamped)
        bookmarks.sort()
        onBookmarksChanged?()
    }

    func removeBookmark(at frame: AVAudioFramePosition) {
        let before = bookmarks.count
        bookmarks.removeAll { abs($0 - frame) < bookmarkTolerance }
        if bookmarks.count != before { onBookmarksChanged?() }
    }

    func clearBookmarks() {
        guard !bookmarks.isEmpty else { return }
        bookmarks.removeAll()
        onBookmarksChanged?()
    }

    func goToBookmark(at frame: AVAudioFramePosition) {
        seek(toFrame: frame)
    }

    func goToNextBookmark() {
        let cur = currentFramePosition
        if let next = bookmarks.first(where: { $0 > cur + bookmarkTolerance }) {
            seek(toFrame: next)
        }
    }

    func goToPreviousBookmark() {
        let cur = currentFramePosition
        if let prev = bookmarks.last(where: { $0 < cur - bookmarkTolerance }) {
            seek(toFrame: prev)
        }
    }

    func goToFirstBookmark() {
        if let first = bookmarks.first { seek(toFrame: first) }
    }

    func goToLastBookmark() {
        if let last = bookmarks.last { seek(toFrame: last) }
    }

    private func applyRegionToCore(seekToStart: Bool) {
        let start = selectionStartFrame
        let end: AVAudioFramePosition
        let looping: Bool
        switch selection {
        case .whole:
            end = totalFrames
            looping = false
        case .region(let s, let length, let loops):
            end = s + AVAudioFramePosition(length)
            looping = loops
        }
        core.setRegion(start: start, end: end, looping: looping, seekToStart: seekToStart)
    }

    // MARK: - Derived positions

    /// Absolute frame offset where the current selection begins.
    var selectionStartFrame: AVAudioFramePosition {
        switch selection {
        case .whole: return 0
        case .region(let start, _, _): return start
        }
    }

    /// Frame count of the active selection (whole file or region).
    var selectionLength: AVAudioFrameCount {
        switch selection {
        case .whole: return fullBuffer?.frameLength ?? 0
        case .region(_, let length, _): return length
        }
    }

    /// Total frame count of the loaded file.
    var totalFrames: AVAudioFramePosition {
        AVAudioFramePosition(fullBuffer?.frameLength ?? 0)
    }

    /// Current playhead position in source-buffer frames (the read cursor).
    var currentFramePosition: AVAudioFramePosition {
        max(0, min(totalFrames, core.playhead))
    }

    /// Audio sample rate, for converting frames to seconds.
    var sampleRate: Double {
        fullBuffer?.format.sampleRate ?? 44_100
    }

    // MARK: - Pitch & time

    /// Pitch offset in cents. Stored as Rubber Band's pitch scale internally.
    var pitchCents: Float {
        get { Float(1200.0 * log2(currentPitchScale)) }
        set {
            currentPitchScale = pow(2.0, Double(newValue) / 1200.0)
            core.setPitchScale(currentPitchScale)
        }
    }

    /// Playback rate. 1.0 = original, 0.5 = half speed, 2.0 = double speed.
    /// Rubber Band's time ratio is the reciprocal of the rate.
    var rate: Float {
        get { Float(1.0 / currentTimeRatio) }
        set {
            let clamped = max(1.0 / 32.0, min(32.0, Double(newValue)))
            currentTimeRatio = 1.0 / clamped
            core.setTimeRatio(currentTimeRatio)
        }
    }

    // MARK: - Output

    /// Output volume. 0.0 = silent, 1.0 = unity, up to 2.0 (200%).
    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = max(0, min(2.0, newValue)) }
    }

    // MARK: - Graph

    /// (Re)build the source → EQ → mixer chain for a given processing format.
    /// The source node is recreated per load because its format is fixed at
    /// construction and files can have different sample rates.
    private func rebuildGraph(format: AVAudioFormat) {
        if let old = sourceNode {
            engine.detach(old)
        }
        let core = self.core
        // The render block MUST be @Sendable. Created inside this @MainActor
        // method, an un-annotated closure is inferred main-actor-isolated, and
        // the Swift runtime then asserts it runs on the main queue. AVFoundation
        // calls it on the realtime audio thread instead, which trapped in
        // _dispatch_assert_queue_fail. @Sendable forces it non-isolated.
        let renderBlock: AVAudioSourceNodeRenderBlock = { @Sendable isSilence, _, frameCount, audioBufferList in
            core.render(frameCount: frameCount,
                        audioBufferList: audioBufferList,
                        isSilence: isSilence)
        }
        let node = AVAudioSourceNode(format: format, renderBlock: renderBlock)
        engine.attach(node)
        engine.connect(node, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        sourceNode = node
    }
}
