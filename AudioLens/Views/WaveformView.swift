import AppKit
import AVFoundation

/// Renders the loaded audio buffer as a min/max overview using Core Graphics.
/// Step 2 will add selection drag, selection overlay, playhead, and loop-mode
/// integration. A Metal-backed version with on-disk overview cache will follow.
@MainActor
final class WaveformView: NSView {

    private var samplesMin: [Float] = []
    private var samplesMax: [Float] = []

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

    func setBuffer(_ buffer: AVAudioPCMBuffer) {
        let bucketCount = max(64, Int(bounds.width))
        let (mins, maxs) = Self.computeOverview(buffer: buffer, buckets: bucketCount)
        self.samplesMin = mins
        self.samplesMax = maxs
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !samplesMax.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
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

    /// Reduces the buffer to `buckets` (min, max) pairs. Float32 non-interleaved
    /// is what SFBAudioEngine's processingFormat yields.
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
