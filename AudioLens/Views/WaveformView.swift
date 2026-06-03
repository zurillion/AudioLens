import AppKit
import AVFoundation

/// Wraps a non-Sendable buffer so it can cross into a detached task. The buffer
/// is only read (here and on the audio thread); nothing mutates it.
private struct BufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

/// Renders the loaded audio buffer with an interactive region/loop and live
/// playhead. Above the waveform is a strip with two draggable handles for the
/// loop edges; below is a strip with bookmark markers. Clicking in the waveform
/// body keeps the original behaviour (click = seek, drag = define region).
@MainActor
final class WaveformView: NSView {

    private enum DragMode {
        case none
        case waveform        // click/seek or region-define in the body
        case loopStart
        case loopEnd
        case bookmark        // dragging a bookmark marker
    }

    /// Heights of the handle strips above and below the waveform body.
    private static let topStrip: CGFloat = 22
    private static let bottomStrip: CGFloat = 22
    /// Hit radius (points) around a handle's x for grabbing it.
    private static let handleHitRadius: CGFloat = 9

    private static let loopColor = NSColor.systemOrange
    private static let bookmarkColor = NSColor.systemTeal

    // MARK: - Overview state

    /// Fixed overview resolution, independent of view width so it survives
    /// resizes and can be cached. `nonisolated` so off-main compute can read it.
    nonisolated private static let maxBuckets = 16_384

    private var mins: [Float] = []
    private var maxs: [Float] = []
    private var bucketCount = 0
    private var validBuckets = 0
    private var totalFrames: AVAudioFramePosition = 0

    private var loadTask: Task<Void, Never>?
    private var overviewGeneration = 0

    // MARK: - Interaction state

    var selection: Selection = .whole {
        didSet { needsDisplay = true }
    }

    var bookmarks: [AVAudioFramePosition] = [] {
        didSet { needsDisplay = true }
    }

    var playheadFrame: AVAudioFramePosition = 0 {
        didSet {
            guard oldValue != playheadFrame else { return }
            needsDisplay = true
        }
    }

    /// Drag in the body defines a new region.
    var onRegionSelected: ((AVAudioFramePosition, AVAudioFrameCount) -> Void)?
    /// Click in the body (or on a bookmark handle) — seek.
    var onSeek: ((AVAudioFramePosition) -> Void)?
    /// Live loop-edge drag from the top handles.
    var onLoopBoundsChanged: ((AVAudioFramePosition, AVAudioFramePosition) -> Void)?
    /// A bookmark marker dragged to a new position (from, to).
    var onBookmarkMoved: ((AVAudioFramePosition, AVAudioFramePosition) -> Void)?
    /// Option-click on a bookmark marker — delete it.
    var onBookmarkDeleted: ((AVAudioFramePosition) -> Void)?

    private let clickDragThreshold: CGFloat = 4
    private var dragMode: DragMode = .none
    private var dragStartPixel: CGFloat?
    private var dragCurrentPixel: CGFloat?
    private var draggedBookmarkFrame: AVAudioFramePosition = 0
    private var bookmarkDidMove = false

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

    // MARK: - Geometry

    private var waveTop: CGFloat { Self.topStrip }
    private var waveBottom: CGFloat { max(Self.topStrip, bounds.height - Self.bottomStrip) }
    private var waveMid: CGFloat { (waveTop + waveBottom) / 2 }
    private var waveHalfHeight: CGFloat { max(1, (waveBottom - waveTop) / 2 - 4) }

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
        bookmarks = []
        dragMode = .none
        dragStartPixel = nil
        dragCurrentPixel = nil
        needsDisplay = true

        let box = BufferBox(buffer: buffer)
        loadTask = Task.detached(priority: .utility) { [weak self] in
            if let url, let cached = WaveformCache.load(for: url) {
                await self?.apply(generation: generation,
                                  mins: cached.mins, maxs: cached.maxs,
                                  valid: cached.mins.count, total: cached.mins.count)
                return
            }
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
        guard generation == overviewGeneration else { return }
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

        // Top strip: grab a loop edge handle if a region is active.
        if point.y <= Self.topStrip, case .region(let start, let length, _) = selection {
            let startX = frameToPixel(start)
            let endX = frameToPixel(start + AVAudioFramePosition(length))
            // Prefer whichever handle is closer if both are near.
            let dStart = abs(point.x - startX)
            let dEnd = abs(point.x - endX)
            if dStart <= Self.handleHitRadius || dEnd <= Self.handleHitRadius {
                dragMode = (dStart <= dEnd) ? .loopStart : .loopEnd
                return
            }
        }

        // Bottom strip: option-click a marker to delete it; otherwise begin a
        // bookmark drag (a plain click without movement seeks there on mouseUp).
        if point.y >= bounds.height - Self.bottomStrip {
            if let frame = nearestBookmark(toPixel: point.x) {
                if event.modifierFlags.contains(.option) {
                    onBookmarkDeleted?(frame)
                } else {
                    dragMode = .bookmark
                    draggedBookmarkFrame = frame
                    dragStartPixel = point.x
                    bookmarkDidMove = false
                }
            }
            return
        }

        // Body: original click/drag behaviour.
        dragMode = .waveform
        dragStartPixel = point.x
        dragCurrentPixel = point.x
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard totalFrames > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)

        switch dragMode {
        case .loopStart, .loopEnd:
            guard case .region(let start, let length, let loops) = selection else { return }
            let end = start + AVAudioFramePosition(length)
            let dragged = pixelToFrame(point.x)
            let newStart: AVAudioFramePosition
            let newEnd: AVAudioFramePosition
            if dragMode == .loopStart {
                newStart = max(0, min(end - 1, dragged))
                newEnd = end
            } else {
                newStart = start
                newEnd = max(start + 1, min(totalFrames, dragged))
            }
            selection = .region(start: newStart,
                                 length: AVAudioFrameCount(newEnd - newStart),
                                 loops: loops)
            onLoopBoundsChanged?(newStart, newEnd)
        case .bookmark:
            if let start = dragStartPixel, abs(point.x - start) >= clickDragThreshold {
                bookmarkDidMove = true
            }
            if bookmarkDidMove {
                let newFrame = max(0, min(totalFrames, pixelToFrame(point.x)))
                onBookmarkMoved?(draggedBookmarkFrame, newFrame)
                draggedBookmarkFrame = newFrame
            }
        case .waveform:
            dragCurrentPixel = point.x
            needsDisplay = true
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let mode = dragMode
        defer {
            dragMode = .none
            dragStartPixel = nil
            dragCurrentPixel = nil
            needsDisplay = true
        }
        // A bookmark marker clicked without dragging seeks to it.
        if mode == .bookmark {
            if !bookmarkDidMove { onSeek?(draggedBookmarkFrame) }
            return
        }
        guard mode == .waveform,
              let startPx = dragStartPixel, let endPx = dragCurrentPixel,
              totalFrames > 0 else {
            return
        }
        let pixelDistance = abs(endPx - startPx)
        if pixelDistance < clickDragThreshold {
            onSeek?(pixelToFrame(startPx))
        } else {
            let lo = pixelToFrame(min(startPx, endPx))
            let hi = pixelToFrame(max(startPx, endPx))
            onRegionSelected?(lo, AVAudioFrameCount(hi - lo))
        }
    }

    private func nearestBookmark(toPixel x: CGFloat) -> AVAudioFramePosition? {
        var best: AVAudioFramePosition?
        var bestDistance = Self.handleHitRadius + 1
        for frame in bookmarks {
            let d = abs(frameToPixel(frame) - x)
            if d < bestDistance {
                bestDistance = d
                best = frame
            }
        }
        return best
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        drawWaveform(ctx)

        if let (lo, hi) = activeSelectionRange() {
            let x1 = frameToPixel(lo)
            let x2 = frameToPixel(hi)
            let fill = NSColor(srgbRed: 1.0, green: 0.85, blue: 0.35, alpha: 0.45)
            ctx.setFillColor(fill.cgColor)
            ctx.fill(NSRect(x: x1, y: waveTop, width: max(1, x2 - x1), height: waveBottom - waveTop))
            drawLoopEdges(ctx, startX: x1, endX: x2)
        }

        drawBookmarks(ctx)

        if totalFrames > 0 {
            let playX = frameToPixel(playheadFrame)
            ctx.setStrokeColor(NSColor.systemRed.cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: playX, y: waveTop))
            ctx.addLine(to: CGPoint(x: playX, y: waveBottom))
            ctx.strokePath()
        }
    }

    /// One vertical min/max line per pixel column, downsampling the overview to
    /// the view width. Only computed buckets (`validBuckets`) are drawn, so the
    /// waveform fills in progressively.
    private func drawWaveform(_ ctx: CGContext) {
        guard bucketCount > 0, validBuckets > 0 else { return }
        let mid = waveMid
        let halfHeight = waveHalfHeight
        let width = bounds.width
        guard width >= 1 else { return }

        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)

        let columns = Int(width)
        for px in 0..<columns {
            let b0 = bucketCount * px / columns
            let b1 = max(b0 + 1, bucketCount * (px + 1) / columns)
            if b0 >= validBuckets { break }
            let end = min(b1, validBuckets)
            var lo: Float = 0
            var hi: Float = 0
            for b in b0..<end {
                if mins[b] < lo { lo = mins[b] }
                if maxs[b] > hi { hi = maxs[b] }
            }
            let x = CGFloat(px) + 0.5
            ctx.move(to: CGPoint(x: x, y: mid - CGFloat(hi) * halfHeight))
            ctx.addLine(to: CGPoint(x: x, y: mid - CGFloat(lo) * halfHeight))
        }
        ctx.strokePath()
    }

    private func drawLoopEdges(_ ctx: CGContext, startX: CGFloat, endX: CGFloat) {
        ctx.setStrokeColor(Self.loopColor.cgColor)
        ctx.setLineWidth(1.5)
        for x in [startX, endX] {
            ctx.move(to: CGPoint(x: x, y: waveTop))
            ctx.addLine(to: CGPoint(x: x, y: waveBottom))
        }
        ctx.strokePath()

        // Grab handles in the top strip.
        ctx.setFillColor(Self.loopColor.cgColor)
        for x in [startX, endX] {
            let handle = NSRect(x: x - 5, y: 3, width: 10, height: Self.topStrip - 7)
            let path = NSBezierPath(roundedRect: handle, xRadius: 3, yRadius: 3)
            path.fill()
        }
    }

    private func drawBookmarks(_ ctx: CGContext) {
        guard !bookmarks.isEmpty, totalFrames > 0 else { return }
        let bottomY = bounds.height
        for frame in bookmarks {
            let x = frameToPixel(frame)
            ctx.setStrokeColor(Self.bookmarkColor.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: x, y: waveTop))
            ctx.addLine(to: CGPoint(x: x, y: waveBottom))
            ctx.strokePath()

            // Flag marker in the bottom strip.
            ctx.setFillColor(Self.bookmarkColor.cgColor)
            let markerTop = bottomY - Self.bottomStrip + 3
            let path = NSBezierPath()
            path.move(to: CGPoint(x: x, y: markerTop))
            path.line(to: CGPoint(x: x - 5, y: markerTop + 6))
            path.line(to: CGPoint(x: x + 5, y: markerTop + 6))
            path.close()
            path.fill()
        }
    }

    private func activeSelectionRange() -> (AVAudioFramePosition, AVAudioFramePosition)? {
        if dragMode == .waveform,
           let s = dragStartPixel, let e = dragCurrentPixel,
           abs(e - s) >= clickDragThreshold {
            return (pixelToFrame(min(s, e)), pixelToFrame(max(s, e)))
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
