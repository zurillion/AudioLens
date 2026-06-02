import AppKit
import AVFoundation

/// Renders the loaded audio buffer with an interactive region selection and a
/// live playhead. Drag horizontally to define a region; a near-zero-width drag
/// (click without movement) clears the selection back to the whole file.
///
/// Future work: Metal-backed renderer, on-disk overview cache, edge handles to
/// resize an existing region, snap to zero-crossings.
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

    /// Called when a click without drag clears the active selection.
    var onSelectionCleared: (() -> Void)?

    private var dragStartFrame: AVAudioFramePosition?
    private var dragCurrentFrame: AVAudioFramePosition?

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
        dragStartFrame = nil
        dragCurrentFrame = nil
        needsDisplay = true
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard totalFrames > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let frame = pixelToFrame(point.x)
        dragStartFrame = frame
        dragCurrentFrame = frame
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStartFrame != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        dragCurrentFrame = pixelToFrame(point.x)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStartFrame = nil
            dragCurrentFrame = nil
            needsDisplay = true
        }
        guard let start = dragStartFrame, let end = dragCurrentFrame, totalFrames > 0 else {
            return
        }
        let lo = min(start, end)
        let hi = max(start, end)
        let length = hi - lo
        let clickThreshold = max(AVAudioFramePosition(1), totalFrames / 500)
        if length < clickThreshold {
            onSelectionCleared?()
        } else {
            onRegionSelected?(lo, AVAudioFrameCount(length))
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        if let (lo, hi) = activeSelectionRange() {
            let x1 = frameToPixel(lo)
            let x2 = frameToPixel(hi)
            ctx.setFillColor(NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35).cgColor)
            ctx.fill(NSRect(x: x1, y: 0, width: max(1, x2 - x1), height: bounds.height))
        }

        drawWaveform(ctx)

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

    /// Returns the (lo, hi) frame range to highlight: the live drag if one is
    /// in progress, otherwise the committed selection (if any).
    private func activeSelectionRange() -> (AVAudioFramePosition, AVAudioFramePosition)? {
        if let s = dragStartFrame, let e = dragCurrentFrame {
            let lo = min(s, e)
            let hi = max(s, e)
            return hi > lo ? (lo, hi) : nil
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
