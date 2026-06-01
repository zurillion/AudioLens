import AppKit
import AVFoundation

/// First-pass waveform renderer using Core Graphics. Reads the audio file in
/// chunks, computes min/max per pixel column, draws filled lines.
///
/// Next steps:
///  - Move to a Metal-backed view for fluid zoom on long files.
///  - Cache the overview (one min/max per pixel at several zoom levels) to disk
///    keyed on a hash of the source file.
///  - Overlay selection regions and playhead.
@MainActor
final class WaveformView: NSView {

    private var samplesMin: [Float] = []
    private var samplesMax: [Float] = []
    private var loadTask: Task<Void, Never>?

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

    func setFile(_ file: AVAudioFile) {
        loadTask?.cancel()
        let url = file.url
        let bucketCount = max(64, Int(bounds.width))
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                try? Self.computeOverview(url: url, buckets: bucketCount)
            }.value
            guard let self, let (mins, maxs) = result else { return }
            self.samplesMin = mins
            self.samplesMax = maxs
            self.needsDisplay = true
        }
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

    /// Reads the file in PCM frames and reduces it to `buckets` (min, max) pairs.
    /// Runs off the main actor and is safe to cancel.
    private static func computeOverview(url: URL, buckets: Int) throws -> ([Float], [Float]) {
        let reader = try AVAudioFile(forReading: url)
        let totalFrames = reader.length
        guard totalFrames > 0, buckets > 0 else { return ([], []) }

        let framesPerBucket = max(1, Int(totalFrames) / buckets)
        let format = reader.processingFormat
        let bufferCapacity = AVAudioFrameCount(framesPerBucket)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferCapacity) else {
            return ([], [])
        }
        var mins = [Float](repeating: 0, count: buckets)
        var maxs = [Float](repeating: 0, count: buckets)

        for bucket in 0..<buckets {
            if Task.isCancelled { break }
            buffer.frameLength = 0
            do {
                try reader.read(into: buffer, frameCount: bufferCapacity)
            } catch {
                break
            }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channelData = buffer.floatChannelData else { break }

            var lo: Float = 0
            var hi: Float = 0
            let channels = Int(format.channelCount)
            for ch in 0..<channels {
                let ptr = channelData[ch]
                for i in 0..<frames {
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
