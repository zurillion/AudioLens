import AppKit
import AVFoundation

/// Renders the loaded audio buffer with an interactive region selection and a
/// live playhead. A horizontal drag defines a region (translucent overlay); a
/// click without measurable drag emits a seek to that point.
@MainActor
final class WaveformView: NSView {

    private var samplesMin: [Float] = []
    private var samplesMax: [Float] = []
    private var totalFrames: AVAudioFramePosition = 0

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

    func setBuffer(_ buffer: AVAudioPCMBuffer) {
        totalFrames = AVAudioFramePosition(buffer.frameLength)
        let bucketCount = max(64, Int(bounds.width))
        let (mins, maxs) = Self.computeOverview(buffer: buffer, buckets: bucketCount)
        self.samplesMin = mins
        self.samplesMax = maxs
        playheadFrame = 0
        selection = .whole
        dragStartPixel = nil
        dragCurrentPixel = nil
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
            // Click — emit a seek.
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

        // Draw the waveform first, then the selection overlay on top of it.
        // The translucent yellow tints the audio inside the loop, making it
        // visually distinct from the un-selected region.
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

    private func drawWaveform(_ ctx: CGContext) {
        guard !samplesMax.isEmpty else { return }
        let mid = bounds.midY
        let halfHeight = bounds.height / 2 - 6
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        let width = bounds.width
        let count = samplesMax.count
        for i in 0..<count {
            let x = width * CGFloat(i) / CGFloat(count)
            let top = mid - CGFloat(samplesMax[i]) * halfHeight
            let bottom = mid - CGFloat(samplesMin[i]) * halfHeight
            ctx.move(to: CGPoint(x: x, y: top))
            ctx.addLine(to: CGPoint(x: x, y: bottom))
        }
        ctx.strokePath()
    }

    /// Returns the (lo, hi) frame range to highlight: the live drag if it
    /// already exceeds the click threshold, otherwise the committed selection.
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

    // MARK: - Overview

    private static func computeOverview(buffer: AVAudioPCMBuffer, buckets: Int) -> ([Float], [Float]) {
        let totalFrames = Int(buffer.frameLength)
        guard totalFrames > 0, buckets > 0,
              let channelData = buffer.floatChannelData else {
            return ([], [])
        }
        let framesPerBucket = max(1, totalFrames / buckets)
        let channels = Int(buffer.format.channelCount)
        var mins = [Float](repeating: 0, count: buckets)
        var maxs = [Float](repeating: 0, count: buckets)
        for bucket in 0..<buckets {
            let start = bucket * framesPerBucket
            let end = min(totalFrames, start + framesPerBucket)
            var lo: Float = 0
            var hi: Float = 0
            for ch in 0..<channels {
                let ptr = channelData[ch]
                for i in start..<end {
                    let v = ptr[i]
                    if v < lo { lo = v }
                    if v > hi { hi = v }
                }
            }
            mins[bucket] = lo
            maxs[bucket] = hi
        }
        return (mins, maxs)
    }
}
