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
        case trimStart       // dragging the left trim marker
        case trimEnd         // dragging the right trim marker
    }

    /// Heights of the handle strips above and below the waveform body.
    private static let topStrip: CGFloat = 22
    private static let bottomStrip: CGFloat = 22
    /// Hit radius (points) around a handle's x for grabbing it.
    private static let handleHitRadius: CGFloat = 9

    private static let loopColor = NSColor.systemOrange
    private static let bookmarkColor = NSColor.systemTeal
    private static let trimColor = NSColor.systemGray

    // MARK: - Overview state

    /// Fixed overview resolution, independent of view width so it survives
    /// resizes and can be cached. `nonisolated` so off-main compute can read it.
    nonisolated private static let maxBuckets = 16_384

    private var mins: [Float] = []
    private var maxs: [Float] = []
    private var bucketCount = 0
    private var validBuckets = 0
    private var totalFrames: AVAudioFramePosition = 0

    /// Strong reference to the decoded PCM, kept so we can read individual
    /// samples for direct-sample drawing once zoom outruns the bucket overview.
    private var pcmBuffer: AVAudioPCMBuffer?

    // MARK: - Zoom window
    //
    // Everything pixel/frame conversion goes through `frameToPixel` and
    // `pixelToFrame`, so changing what these two functions consider the
    // "visible range" is what makes the entire view zoom — overlays, hit
    // tests, drag, playhead all follow automatically.

    /// Inclusive start of the visible frame range.
    private var visibleStart: AVAudioFramePosition = 0
    /// Exclusive end of the visible frame range. `visibleStart..<visibleEnd`
    /// is what occupies `0..<bounds.width` in pixel space. At `1×` zoom this
    /// is `0..<totalFrames`.
    private var visibleEnd: AVAudioFramePosition = 0

    /// During playback, scroll forward (DAW-style) when the playhead nears the
    /// right edge of the visible window. Turned off by any user pan/zoom; the
    /// "fit-to-view" gesture (double-click body) turns it back on.
    private var autoFollowPlayhead = true

    /// Accumulator for incremental pinch deltas (the recognizer reports a
    /// running total during the gesture).
    private var pinchAccumulator: CGFloat = 0

    private var loadTask: Task<Void, Never>?
    private var overviewGeneration = 0

    /// True from the moment a load is requested until the first overview slice
    /// (or the cached overview) is ready. While set, the body shows "Loading…".
    private var isLoading = false {
        didSet { needsDisplay = true }
    }

    // MARK: - Interaction state

    var selection: Selection = .whole {
        didSet { needsDisplay = true }
    }

    var bookmarks: [AVAudioFramePosition] = [] {
        didSet { needsDisplay = true }
    }

    /// Trim markers (always present). Everything left of `trimStartFrame` and
    /// right of `trimEndFrame` is greyed out and inaccessible.
    var trimStartFrame: AVAudioFramePosition = 0 {
        didSet { needsDisplay = true }
    }
    var trimEndFrame: AVAudioFramePosition = 0 {
        didSet { needsDisplay = true }
    }

    var playheadFrame: AVAudioFramePosition = 0 {
        didSet {
            guard oldValue != playheadFrame else { return }
            positionPlayhead()        // move the layer; no full redraw
            maybePageForPlayhead()    // DAW-style auto-scroll while playing
        }
    }

    /// The playhead is a thin layer moved on every tick, so playback doesn't
    /// trigger a full waveform redraw 24×/s (heavy enough to occasionally
    /// drop mouse/key events).
    private let playheadLayer = CALayer()

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
    /// Command-click on a bookmark marker — rename it.
    var onBookmarkRenameRequested: ((AVAudioFramePosition) -> Void)?
    /// Live trim-marker drag (start, end).
    var onTrimChanged: ((AVAudioFramePosition, AVAudioFramePosition) -> Void)?

    private let clickDragThreshold: CGFloat = 6
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

        playheadLayer.backgroundColor = NSColor.systemRed.cgColor
        // Disable implicit animations so the line tracks instantly.
        playheadLayer.actions = [
            "position": NSNull(), "bounds": NSNull(),
            "frame": NSNull(), "hidden": NSNull()
        ]
        playheadLayer.isHidden = true
        layer?.addSublayer(playheadLayer)

        // Trackpad pinch zoom. The recognizer reports a running magnification
        // value during the gesture, which we read incrementally and reset.
        let pinch = NSMagnificationGestureRecognizer(
            target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)
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

    /// Called as soon as a file open/drop begins — before the (possibly slow)
    /// decode — so the body shows "Loading…" and the previous waveform is
    /// cleared right away rather than lingering under the new one.
    func beginLoading() {
        loadTask?.cancel()
        overviewGeneration &+= 1   // invalidate any in-flight apply
        isLoading = true
        mins = []
        maxs = []
        bucketCount = 0
        validBuckets = 0
        totalFrames = 0
        visibleStart = 0
        visibleEnd = 0
        autoFollowPlayhead = true
        pcmBuffer = nil
        trimStartFrame = 0
        trimEndFrame = 0
        playheadFrame = 0
        selection = .whole
        bookmarks = []
        dragMode = .none
        dragStartPixel = nil
        dragCurrentPixel = nil
        positionPlayhead()   // totalFrames == 0 → hides the playhead line
        needsDisplay = true
    }

    /// Clear the loading state without data (e.g. a decode error), so "Loading…"
    /// doesn't linger forever.
    func cancelLoading() {
        isLoading = false
        needsDisplay = true
    }

    func setBuffer(_ buffer: AVAudioPCMBuffer, url: URL?) {
        loadTask?.cancel()
        overviewGeneration &+= 1
        let generation = overviewGeneration

        isLoading = true
        totalFrames = AVAudioFramePosition(buffer.frameLength)
        // Reset zoom to 1× (whole-file view) for each new load.
        visibleStart = 0
        visibleEnd = totalFrames
        autoFollowPlayhead = true
        pcmBuffer = buffer
        trimStartFrame = 0
        trimEndFrame = totalFrames
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
        // The first usable slice (or the cached overview) clears "Loading…".
        if valid > 0 { isLoading = false }
        needsDisplay = true
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard totalFrames > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)

        // Top strip: grab the nearest handle. The two always-present trim
        // handles plus, when a region is active, the two loop-edge handles all
        // live here; pick whichever is closest within the hit radius. Loop
        // handles are listed first so they win an exact tie with a trim edge.
        if point.y <= Self.topStrip {
            var candidates: [(DragMode, CGFloat)] = []
            if case .region(let start, let length, _) = selection {
                candidates.append((.loopStart, frameToPixel(start)))
                candidates.append((.loopEnd, frameToPixel(start + AVAudioFramePosition(length))))
            }
            candidates.append((.trimStart, frameToPixel(trimStartFrame)))
            candidates.append((.trimEnd, frameToPixel(trimEndFrame)))

            var best: DragMode?
            var bestDistance = Self.handleHitRadius + 1
            for (mode, x) in candidates {
                let d = abs(point.x - x)
                if d <= Self.handleHitRadius && d < bestDistance {
                    bestDistance = d
                    best = mode
                }
            }
            if let best {
                dragMode = best
                return
            }
        }

        // Bottom strip: option-click a marker to delete it; otherwise begin a
        // bookmark drag (a plain click without movement seeks there on mouseUp).
        if point.y >= bounds.height - Self.bottomStrip {
            if let frame = nearestBookmark(toPixel: point.x) {
                if event.modifierFlags.contains(.option) {
                    onBookmarkDeleted?(frame)
                } else if event.modifierFlags.contains(.command) {
                    onBookmarkRenameRequested?(frame)
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
            // Loop edges can't escape the trimmed, accessible range.
            if dragMode == .loopStart {
                newStart = max(trimStartFrame, min(end - 1, dragged))
                newEnd = end
            } else {
                newStart = start
                newEnd = max(start + 1, min(trimEndFrame, dragged))
            }
            selection = .region(start: newStart,
                                 length: AVAudioFrameCount(newEnd - newStart),
                                 loops: loops)
            onLoopBoundsChanged?(newStart, newEnd)
        case .trimStart:
            // Left trim marker; can't pass the right one.
            let newStart = max(0, min(trimEndFrame - 1, pixelToFrame(point.x)))
            trimStartFrame = newStart
            onTrimChanged?(newStart, trimEndFrame)
        case .trimEnd:
            // Right trim marker; can't pass the left one.
            let newEnd = min(totalFrames, max(trimStartFrame + 1, pixelToFrame(point.x)))
            trimEndFrame = newEnd
            onTrimChanged?(trimStartFrame, newEnd)
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

    private func mouseUpDefault(_ event: NSEvent) {
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

    // MARK: - Zoom

    /// Current zoom factor relative to 1× (whole file). 1× = entire file in view.
    var zoomFactor: Double {
        guard totalFrames > 0, visibleLength > 0 else { return 1 }
        return Double(totalFrames) / Double(visibleLength)
    }

    /// Zoom by `factor` (>1 = zoom in, <1 = zoom out), pinning the frame
    /// currently under `anchorPx` so it stays under that same pixel after the
    /// zoom. Clamps at 1× (whole file) and at 1 frame per pixel.
    func zoom(by factor: Double, anchoredAtPixel anchorPx: CGFloat) {
        guard totalFrames > 0, bounds.width > 0 else { return }
        let anchorFrame = pixelToFrame(anchorPx)

        let minLen = max(AVAudioFramePosition(bounds.width), 1)   // 1 frame/pixel
        let maxLen = totalFrames                                  // 1× zoom
        let proposed = Double(visibleEnd - visibleStart) / factor
        var newLen = AVAudioFramePosition(proposed.rounded())
        newLen = max(minLen, min(maxLen, newLen))

        // Solve: anchorPx / width = (anchorFrame - newStart) / newLen.
        let anchorRatio = Double(anchorPx / bounds.width)
        var newStart = AVAudioFramePosition(
            Double(anchorFrame) - anchorRatio * Double(newLen))
        var newEnd = newStart + newLen

        // Clamp window inside [0, totalFrames] without changing its length.
        if newStart < 0 {
            newEnd -= newStart
            newStart = 0
        }
        if newEnd > totalFrames {
            newStart -= (newEnd - totalFrames)
            newEnd = totalFrames
        }
        newStart = max(0, newStart)
        newEnd = min(totalFrames, newEnd)

        visibleStart = newStart
        visibleEnd = newEnd
        // Zoom alone doesn't disable auto-follow: the user is just looking
        // more closely. Only an explicit *pan* (which means "show me a
        // different spot") shuts off the follow.
        positionPlayhead()
        needsDisplay = true
    }

    /// Centered zoom-in, used by the toolbar buttons.
    func zoomInCentered() { zoom(by: 1.5, anchoredAtPixel: bounds.width / 2) }
    /// Centered zoom-out, used by the toolbar buttons.
    func zoomOutCentered() { zoom(by: 1.0 / 1.5, anchoredAtPixel: bounds.width / 2) }

    /// Reset to 1× zoom and re-enable auto-follow.
    func resetZoom() {
        visibleStart = 0
        visibleEnd = totalFrames
        autoFollowPlayhead = true
        positionPlayhead()
        needsDisplay = true
    }

    /// Shift the visible window by `dxPixels` (positive = scroll forward).
    private func panByPixels(_ dxPixels: CGFloat) {
        guard totalFrames > 0, bounds.width > 0 else { return }
        let len = visibleEnd - visibleStart
        guard len < totalFrames else { return }   // nothing to scroll
        let shift = AVAudioFramePosition(
            (Double(dxPixels) / Double(bounds.width) * Double(len)).rounded())
        if shift == 0 { return }
        var newStart = visibleStart - shift   // natural scrolling: content follows fingers
        newStart = max(0, min(totalFrames - len, newStart))
        if newStart == visibleStart { return }
        visibleStart = newStart
        visibleEnd = visibleStart + len
        autoFollowPlayhead = false
        positionPlayhead()
        needsDisplay = true
    }

    @objc private func handlePinch(_ recognizer: NSMagnificationGestureRecognizer) {
        // The recognizer reports running total magnification; read the delta
        // we haven't acted on yet, then "consume" it by updating the
        // accumulator. (Setting `magnification = 0` on AppKit was unreliable
        // in older OS versions; tracking our own accumulator is safe.)
        let total = recognizer.magnification
        let delta = total - pinchAccumulator
        pinchAccumulator = total
        if recognizer.state == .ended || recognizer.state == .cancelled {
            pinchAccumulator = 0
        }
        let factor = 1.0 + Double(delta)
        guard factor > 0 else { return }
        let p = recognizer.location(in: self)
        zoom(by: factor, anchoredAtPixel: p.x)
    }

    override func scrollWheel(with event: NSEvent) {
        guard totalFrames > 0 else { return }
        let here = convert(event.locationInWindow, from: nil)

        if event.modifierFlags.contains(.command) {
            // Cmd+scroll: zoom around the cursor. Use deltaY (mouse wheels
            // typically only have a vertical axis).
            let dy = Double(event.scrollingDeltaY)
            if dy == 0 { return }
            let factor = exp(dy * 0.01)
            zoom(by: factor, anchoredAtPixel: here.x)
            return
        }

        // Plain scroll: horizontal pan. Trackpads supply deltaX directly;
        // mouse wheels deliver only deltaY, which we map to horizontal too so
        // users without a horizontal axis can still navigate.
        let dx: CGFloat
        if event.scrollingDeltaX != 0 {
            dx = event.scrollingDeltaX
        } else if event.scrollingDeltaY != 0 {
            dx = event.scrollingDeltaY
        } else {
            return
        }
        panByPixels(dx)
    }

    /// Double-click in the body resets zoom to 1× and re-arms auto-follow —
    /// the "fit to view" gesture.
    override func mouseUp(with event: NSEvent) {
        if event.clickCount >= 2, dragMode == .waveform {
            // Cancel the pending click-seek and reset zoom instead.
            dragMode = .none
            dragStartPixel = nil
            dragCurrentPixel = nil
            resetZoom()
            return
        }
        mouseUpDefault(event)
    }

    // MARK: - Auto-follow

    /// Called from the playhead update path. If auto-follow is on and the
    /// playhead reaches the right edge of the visible window, page forward so
    /// it lands near the left side (DAW-style scrolling).
    private func maybePageForPlayhead() {
        guard autoFollowPlayhead,
              totalFrames > 0,
              visibleLength < totalFrames else { return }
        let viewPos = Double(playheadFrame - visibleStart) / Double(visibleLength)
        if viewPos > 0.85 {
            // Place the playhead at 15% of the new window.
            let newStart = playheadFrame
                - AVAudioFramePosition(Double(visibleLength) * 0.15)
            let clamped = max(0, min(totalFrames - visibleLength, newStart))
            if clamped != visibleStart {
                visibleStart = clamped
                visibleEnd = visibleStart + visibleLength
                needsDisplay = true
            }
        } else if viewPos < 0 {
            // Playhead jumped backward off-screen (e.g. seek): recenter.
            let newStart = max(0, playheadFrame
                - AVAudioFramePosition(Double(visibleLength) * 0.15))
            visibleStart = min(totalFrames - visibleLength, newStart)
            visibleEnd = visibleStart + visibleLength
            needsDisplay = true
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // While decoding / computing the overview, show only "Loading…".
        if isLoading && validBuckets == 0 {
            drawLoadingText()
            return
        }

        drawWaveform(ctx)
        drawTrim(ctx)

        if let (lo, hi) = activeSelectionRange() {
            let x1 = frameToPixel(lo)
            let x2 = frameToPixel(hi)
            let fill = NSColor(srgbRed: 1.0, green: 0.85, blue: 0.35, alpha: 0.45)
            ctx.setFillColor(fill.cgColor)
            ctx.fill(NSRect(x: x1, y: waveTop, width: max(1, x2 - x1), height: waveBottom - waveTop))
            drawLoopEdges(ctx, startX: x1, endX: x2)
        }

        drawBookmarks(ctx)
        // The playhead is a separate layer (positionPlayhead), not drawn here.
    }

    /// Centered "Loading…" in blue, shown while the file decodes / the overview
    /// is computed. Drawn via NSAttributedString, which respects the flipped
    /// view's coordinate system inside `draw(_:)`.
    private func drawLoadingText() {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .medium),
            .foregroundColor: NSColor.systemBlue,
        ]
        let attr = NSAttributedString(string: "Loading…", attributes: attrs)
        let size = attr.size()
        let origin = CGPoint(x: (bounds.width - size.width) / 2,
                             y: (bounds.height - size.height) / 2)
        attr.draw(at: origin)
    }

    override func layout() {
        super.layout()
        positionPlayhead()
    }

    private func positionPlayhead() {
        guard totalFrames > 0 else {
            playheadLayer.isHidden = true
            return
        }
        let x = frameToPixel(playheadFrame)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playheadLayer.isHidden = false
        playheadLayer.frame = CGRect(x: x, y: waveTop, width: 1, height: max(1, waveBottom - waveTop))
        CATransaction.commit()
    }

    /// One vertical min/max line per pixel column, downsampling whatever data
    /// covers the visible window. Below ~1 bucket per pixel the overview runs
    /// out of resolution, so we switch to reading individual samples from the
    /// PCM buffer (which is already in RAM — free at any zoom).
    private func drawWaveform(_ ctx: CGContext) {
        guard totalFrames > 0 else { return }
        let width = bounds.width
        guard width >= 1 else { return }

        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)

        let columns = Int(width)
        let visibleFrames = visibleEnd - visibleStart
        // Map the visible window onto the bucket array.
        let firstBucket = Int(Double(visibleStart) * Double(bucketCount) / Double(totalFrames))
        let lastBucket = Int((Double(visibleEnd) * Double(bucketCount) / Double(totalFrames)).rounded(.up))
        let visibleBuckets = max(0, lastBucket - firstBucket)
        let bucketsPerColumn = Double(visibleBuckets) / Double(max(1, columns))

        // If we don't even have one overview bucket per pixel, the overview is
        // visually too coarse: switch to reading the PCM buffer directly.
        if bucketsPerColumn < 1.0, pcmBuffer != nil {
            drawDirectSamples(ctx, columns: columns,
                              visibleFrames: visibleFrames,
                              width: width)
            return
        }

        guard bucketCount > 0, validBuckets > 0, visibleBuckets > 0 else { return }
        let mid = waveMid
        let halfHeight = waveHalfHeight

        for px in 0..<columns {
            let b0 = firstBucket + visibleBuckets * px / columns
            let b1 = max(b0 + 1, firstBucket + visibleBuckets * (px + 1) / columns)
            // Clamp to what's actually computed (the overview fills in
            // progressively in the background).
            let cb0 = max(0, min(validBuckets - 1, b0))
            let cb1 = max(cb0 + 1, min(validBuckets, b1))
            if cb0 >= validBuckets { break }
            var lo: Float = 0
            var hi: Float = 0
            for b in cb0..<cb1 {
                if mins[b] < lo { lo = mins[b] }
                if maxs[b] > hi { hi = maxs[b] }
            }
            let x = CGFloat(px) + 0.5
            ctx.move(to: CGPoint(x: x, y: mid - CGFloat(hi) * halfHeight))
            ctx.addLine(to: CGPoint(x: x, y: mid - CGFloat(lo) * halfHeight))
        }
        ctx.strokePath()
    }

    /// At high zoom (overview too coarse) we read straight from the PCM
    /// buffer — peaks per pixel column over the visible frames. The buffer is
    /// already resident in RAM so this is just float reads, no I/O.
    private func drawDirectSamples(_ ctx: CGContext, columns: Int,
                                   visibleFrames: AVAudioFramePosition,
                                   width: CGFloat) {
        guard let buffer = pcmBuffer,
              let channelData = buffer.floatChannelData,
              visibleFrames > 0, columns > 0 else { return }
        let channels = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        let mid = waveMid
        let halfHeight = waveHalfHeight
        let framesPerColumn = Double(visibleFrames) / Double(columns)

        for px in 0..<columns {
            let f0 = visibleStart + AVAudioFramePosition(Double(px) * framesPerColumn)
            let f1 = visibleStart + AVAudioFramePosition(Double(px + 1) * framesPerColumn)
            let cf0 = max(0, min(frameLength - 1, Int(f0)))
            let cf1 = max(cf0 + 1, min(frameLength, Int(f1)))
            var lo: Float = 0
            var hi: Float = 0
            for ch in 0..<channels {
                let ptr = channelData[ch]
                var i = cf0
                while i < cf1 {
                    let v = ptr[i]
                    if v < lo { lo = v }
                    if v > hi { hi = v }
                    i += 1
                }
            }
            let x = CGFloat(px) + 0.5
            ctx.move(to: CGPoint(x: x, y: mid - CGFloat(hi) * halfHeight))
            ctx.addLine(to: CGPoint(x: x, y: mid - CGFloat(lo) * halfHeight))
        }
        ctx.strokePath()
    }

    /// Grey out the inaccessible head/tail outside the trim markers and draw the
    /// two always-present trim boundary lines plus their top-strip grab handles.
    ///
    /// With zoom, the trim x positions can land outside the view. We still
    /// draw the grey overlay for whatever portion is visible, but skip the
    /// boundary line + handle when off-screen.
    private func drawTrim(_ ctx: CGContext) {
        guard totalFrames > 0 else { return }
        let startX = frameToPixel(trimStartFrame)
        let endX = frameToPixel(trimEndFrame)
        let top = waveTop
        let height = waveBottom - waveTop
        let viewWidth = bounds.width

        // Wash inaccessible regions; clip the rect to the view.
        let overlay = NSColor.textBackgroundColor.withAlphaComponent(0.72)
        ctx.setFillColor(overlay.cgColor)
        if startX > 0 {
            let w = min(startX, viewWidth)
            ctx.fill(NSRect(x: 0, y: top, width: w, height: height))
        }
        if endX < viewWidth {
            let x = max(0, endX)
            ctx.fill(NSRect(x: x, y: top, width: viewWidth - x, height: height))
        }

        // Boundary lines + grab handles — only when the marker itself is in view.
        ctx.setStrokeColor(Self.trimColor.cgColor)
        ctx.setLineWidth(1.5)
        for x in [startX, endX] where x >= 0 && x <= viewWidth {
            ctx.move(to: CGPoint(x: x, y: waveTop))
            ctx.addLine(to: CGPoint(x: x, y: waveBottom))
        }
        ctx.strokePath()

        ctx.setFillColor(Self.trimColor.cgColor)
        for x in [startX, endX] where x >= 0 && x <= viewWidth {
            let handle = NSRect(x: x - 4, y: 3, width: 8, height: Self.topStrip - 7)
            let path = NSBezierPath(roundedRect: handle, xRadius: 2, yRadius: 2)
            path.fill()
        }
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
            // A bookmark stranded outside the trim is unreachable by navigation;
            // draw it greyed (but still hit-testable, so it can be deleted).
            let trimmed = frame < trimStartFrame || frame > trimEndFrame
            let lineColor = trimmed ? Self.trimColor : Self.bookmarkColor
            let flagColor = trimmed ? Self.trimColor : Self.bookmarkColor
            ctx.setStrokeColor(lineColor.withAlphaComponent(trimmed ? 0.5 : 0.9).cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: x, y: waveTop))
            ctx.addLine(to: CGPoint(x: x, y: waveBottom))
            ctx.strokePath()

            // Flag marker in the bottom strip.
            ctx.setFillColor(flagColor.withAlphaComponent(trimmed ? 0.5 : 1.0).cgColor)
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

    /// Pixel `x` (clamped to bounds) → frame inside the visible window.
    private func pixelToFrame(_ x: CGFloat) -> AVAudioFramePosition {
        guard bounds.width > 0, visibleEnd > visibleStart else { return visibleStart }
        let ratio = max(0, min(1, Double(x / bounds.width)))
        return visibleStart + AVAudioFramePosition(Double(visibleEnd - visibleStart) * ratio)
    }

    /// Frame → pixel x. Off-window frames produce off-bounds x values, which
    /// drawing naturally clips and hit tests naturally miss.
    private func frameToPixel(_ frame: AVAudioFramePosition) -> CGFloat {
        guard visibleEnd > visibleStart else { return 0 }
        return bounds.width
            * CGFloat(Double(frame - visibleStart) / Double(visibleEnd - visibleStart))
    }

    private var visibleLength: AVAudioFramePosition { max(1, visibleEnd - visibleStart) }

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
