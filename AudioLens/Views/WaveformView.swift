import AppKit
import AVFoundation

/// Wraps a non-Sendable buffer so it can cross into a detached task. The buffer
/// is only read (here and on the audio thread); nothing mutates it.
private struct BufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

/// Renders the loaded audio buffer with an interactive region selection and a
/// live playhead. The min/max overview is computed off the main thread in
/// slices and shown progressively (the waveform fills left to right as it's
/// built), and cached on disk so reopening a file is instant.
@MainActor
final class WaveformView: NSView {

    /// Fixed overview resolution. Independent of the view width so it survives
    /// resizes and can be cached/reused; the draw step downsamples to pixels.
    /// `nonisolated` so the off-main overview computation can read it.
    nonisolated private static let maxBuckets = 16_384

    private var mins: [Float] = []
    private var maxs: [Float] = []
    private var bucketCount = 0
    private var validBuckets = 0
    private var totalFrames: AVAudioFramePosition = 0

    private var loadTask: Task<Void, Never>?
    private var overviewGeneration = 0

    var selection: Selection = .whole {
        didSet { needsDisplay = true }
    }

    var playheadFrame: AVAudioFramePosition = 0 {
        didSet {
            guard oldValue != playheadFrame else { return }
            needsDisplay = true
        }
    }

    /// Called when the user finishes a drag that defines a new region.
    var onRegionSelected: ((AVAudioFramePosition, AVAudioFrameCount) -> Void)?

    /// Called when the user clicks without dragging — seek to that frame.
    var onSeek: ((AVAudioFramePosition) -> Void)?

    /// Pixel distance below which a mouse event is treated as a click (seek)
    /// rather than a drag (region selection).
    private let clickDragThreshold: CGFloat = 4

    private var dragStartPixel: CGFloat?
    private var dragCurrentPixel: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Loading the overview

    func setBuffer(_ buffer: AVAudioPCMBuffer, url: URL?) {
        loadTask?.cancel()
        overviewGeneration &+= 1
        let generation = overviewGeneration

        totalFrames = AVAudioFramePosition(buffer.frameLength)
        mins = []
        maxs = []
        bucketCount = 0
        validBuckets = 0
        playheadFrame = 0
        selection = .whole
        dragStartPixel = nil
        dragCurrentPixel = nil
        needsDisplay = true

        let box = BufferBox(buffer: buffer)
        loadTask = Task.detached(priority: .utility) { [weak self] in
            // Cache hit: load and display immediately.
            if let url, let cached = WaveformCache.load(for: url) {
                await self?.apply(generation: generation,
                                  mins: cached.mins, maxs: cached.maxs,
                                  valid: cached.mins.count, total: cached.mins.count)
                return
            }

            // Otherwise compute progressively, then persist.
            let result = Self.computeOverview(buffer: box.buffer) { partialMins, partialMaxs, valid, total in
                Task { @MainActor in
                    self?.apply(generation: generation,
                                mins: partialMins, maxs: partialMaxs, valid: valid, total: total)
                }
            }
            if Task.isCancelled { return }
            if let result, let url {
                WaveformCache.save(mins: result.mins, maxs: result.maxs, for: url)
            }
        }
    }

    private func apply(generation: Int, mins: [Float], maxs: [Float], valid: Int, total: Int) {
        guard generation == overviewGeneration else { return }   // stale compute
        self.mins = mins
        self.maxs = maxs
        self.validBuckets = valid
        self.bucketCount = total
        needsDisplay = true
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard totalFrames > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        dragStartPixel = point.x
        dragCurrentPixel = point.x
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStartPixel != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        dragCurrentPixel = point.x
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStartPixel = nil
            dragCurrentPixel = nil
            needsDisplay = true
        }
        guard let startPx = dragStartPixel, let endPx = dragCurrentPixel, totalFrames > 0 else {
            return
        }
        let pixelDistance = abs(endPx - startPx)
        if pixelDistance < clickDragThreshold {
            onSeek?(pixelToFrame(startPx))
        } else {
            let loPx = min(startPx, endPx)
            let hiPx = max(startPx, endPx)
            let lo = pixelToFrame(loPx)
            let hi = pixelToFrame(hiPx)
            onRegionSelected?(lo, AVAudioFrameCount(hi - lo))
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        drawWaveform(ctx)

        if let (lo, hi) = activeSelectionRange() {
            let x1 = frameToPixel(lo)
            let x2 = frameToPixel(hi)
            let highlight = NSColor(srgbRed: 1.0, green: 0.85, blue: 0.35, alpha: 0.45)
            ctx.setFillColor(highlight.cgColor)
            ctx.fill(NSRect(x: x1, y: 0, width: max(1, x2 - x1), height: bounds.height))
        }

        if totalFrames > 0 {
            let playX = frameToPixel(playheadFrame)
            ctx.setStrokeColor(NSColor.systemRed.cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: playX, y: 0))
            ctx.addLine(to: CGPoint(x: playX, y: bounds.height))
            ctx.strokePath()
        }
    }

    /// Draws one vertical min/max line per pixel column, downsampling the
    /// fixed-resolution overview to the view width. Only the buckets computed
    /// so far (`validBuckets`) are drawn, so the waveform appears progressively.
    private func drawWaveform(_ ctx: CGContext) {
        guard bucketCount > 0, validBuckets > 0 else { return }
        let mid = bounds.midY
        let halfHeight = bounds.height / 2 - 6
        let width = bounds.width
        guard width >= 1 else { return }

        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)

        let columns = Int(width)
        for px in 0..<columns {
            // Bucket range covered by this pixel column.
            let b0 = bucketCount * px / columns
            let b1 = max(b0 + 1, bucketCount * (px + 1) / columns)
            if b0 >= validBuckets { break }   // not computed yet
            let end = min(b1, validBuckets)
            var lo: Float = 0
            var hi: Float = 0
            for b in b0..<end {
                if mins[b] < lo { lo = mins[b] }
                if maxs[b] > hi { hi = maxs[b] }
            }
            let x = CGFloat(px) + 0.5
            let top = mid - CGFloat(hi) * halfHeight
            let bottom = mid - CGFloat(lo) * halfHeight
            ctx.move(to: CGPoint(x: x, y: top))
            ctx.addLine(to: CGPoint(x: x, y: bottom))
        }
        ctx.strokePath()
    }

    private func activeSelectionRange() -> (AVAudioFramePosition, AVAudioFramePosition)? {
        if let s = dragStartPixel, let e = dragCurrentPixel,
           abs(e - s) >= clickDragThreshold {
            let loPx = min(s, e)
            let hiPx = max(s, e)
            return (pixelToFrame(loPx), pixelToFrame(hiPx))
        }
        switch selection {
        case .whole:
            return nil
        case .region(let start, let length, _):
            return (start, start + AVAudioFramePosition(length))
        }
    }

    // MARK: - Coordinate mapping

    private func pixelToFrame(_ x: CGFloat) -> AVAudioFramePosition {
        guard bounds.width > 0 else { return 0 }
        let ratio = max(0, min(1, Double(x / bounds.width)))
        return AVAudioFramePosition(Double(totalFrames) * ratio)
    }

    private func frameToPixel(_ frame: AVAudioFramePosition) -> CGFloat {
        guard totalFrames > 0 else { return 0 }
        let clamped = max(0, min(totalFrames, frame))
        return bounds.width * CGFloat(Double(clamped) / Double(totalFrames))
    }

    // MARK: - Overview computation (off-main)

    /// Computes the min/max overview in slices, invoking `onProgress` after each
    /// slice with the arrays-so-far. Returns the final overview, or nil if
    /// cancelled / empty. Runs on a detached task — must not touch the view.
    nonisolated private static func computeOverview(
        buffer: AVAudioPCMBuffer,
        onProgress: ([Float], [Float], Int, Int) -> Void
    ) -> (mins: [Float], maxs: [Float])? {
        let totalFrames = Int(buffer.frameLength)
        guard totalFrames > 0, let channelData = buffer.floatChannelData else { return nil }

        let bucketCount = min(totalFrames, maxBuckets)
        guard bucketCount > 0 else { return nil }
        let channels = Int(buffer.format.channelCount)
        let framesPerBucket = Double(totalFrames) / Double(bucketCount)

        var mins = [Float](repeating: 0, count: bucketCount)
        var maxs = [Float](repeating: 0, count: bucketCount)

        let sliceCount = 48
        for slice in 0..<sliceCount {
            if Task.isCancelled { return nil }
            let bStart = bucketCount * slice / sliceCount
            let bEnd = bucketCount * (slice + 1) / sliceCount
            for b in bStart..<bEnd {
                let f0 = Int(Double(b) * framesPerBucket)
                let f1 = (b == bucketCount - 1) ? totalFrames : Int(Double(b + 1) * framesPerBucket)
                var lo: Float = 0
                var hi: Float = 0
                for ch in 0..<channels {
                    let ptr = channelData[ch]
                    var i = f0
                    while i < f1 {
                        let v = ptr[i]
                        if v < lo { lo = v }
                        if v > hi { hi = v }
                        i += 1
                    }
                }
                mins[b] = lo
                maxs[b] = hi
            }
            onProgress(mins, maxs, bEnd, bucketCount)
        }
        return (mins, maxs)
    }
}
