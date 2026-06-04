import AppKit

/// Stereo peak meter. The audio engine writes per-buffer peaks into a lock-
/// protected accumulator; the UI calls `update(...)` at its tick rate to drain
/// the latest peak, apply ballistic decay, and redraw.
///
/// Visual: two horizontal bars (L on top, R below). Fill colour is green up to
/// −12 dBFS, amber from −12 to −3 dBFS, red above −3 dBFS. A thin coloured
/// line marks the recent peak hold.
@MainActor
final class VUMeterView: NSView {

    // dBFS range shown on the bar.
    private static let minDB: Float = -54
    private static let maxDB: Float = 0
    private static let amberDB: Float = -12
    private static let redDB: Float = -3

    private static let greenColor = NSColor(srgbRed: 0.30, green: 0.85, blue: 0.40, alpha: 1.0)
    private static let amberColor = NSColor(srgbRed: 1.00, green: 0.78, blue: 0.20, alpha: 1.0)
    private static let redColor   = NSColor(srgbRed: 1.00, green: 0.32, blue: 0.28, alpha: 1.0)

    private var leftLevel: Float = 0     // ballistic display level (linear)
    private var rightLevel: Float = 0
    private var leftPeakHold: Float = 0
    private var rightPeakHold: Float = 0
    private var leftPeakAge: TimeInterval = 0
    private var rightPeakAge: TimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = 4
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// Apply a new peak observation (linear amplitude, ≥ 0) and the time since
    /// the previous tick. The bar rises instantly to the peak and decays at
    /// ~30 dB/s; the hold marker lingers ~1.5 s before falling.
    func update(leftPeak rawL: Float, rightPeak rawR: Float, deltaTime dt: TimeInterval) {
        let decay = powf(10.0, Float(-30.0 * dt / 20.0))
        leftLevel = max(rawL, leftLevel * decay)
        rightLevel = max(rawR, rightLevel * decay)

        let holdTime: TimeInterval = 1.5
        if rawL >= leftPeakHold {
            leftPeakHold = rawL
            leftPeakAge = 0
        } else {
            leftPeakAge += dt
            if leftPeakAge > holdTime { leftPeakHold *= 0.92 }
        }
        if rawR >= rightPeakHold {
            rightPeakHold = rawR
            rightPeakAge = 0
        } else {
            rightPeakAge += dt
            if rightPeakAge > holdTime { rightPeakHold *= 0.92 }
        }

        needsDisplay = true
    }

    /// Wipe the meter (e.g. on file change).
    func reset() {
        leftLevel = 0
        rightLevel = 0
        leftPeakHold = 0
        rightPeakHold = 0
        leftPeakAge = 0
        rightPeakAge = 0
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let padding: CGFloat = 3
        let labelWidth: CGFloat = 14
        let gap: CGFloat = 2
        let barX = padding + labelWidth
        let barWidth = max(20, bounds.width - barX - padding)
        let availHeight = bounds.height - 2 * padding - gap
        let barHeight = max(4, availHeight / 2)
        let topY = padding
        let botY = padding + barHeight + gap

        drawBar(ctx, x: barX, y: topY, width: barWidth, height: barHeight,
                level: leftLevel, peak: leftPeakHold)
        drawBar(ctx, x: barX, y: botY, width: barWidth, height: barHeight,
                level: rightLevel, peak: rightPeakHold)

        drawChannelLabel("L", ctx: ctx, x: padding, y: topY, height: barHeight)
        drawChannelLabel("R", ctx: ctx, x: padding, y: botY, height: barHeight)
    }

    private func drawChannelLabel(_ text: String, ctx: CGContext,
                                  x: CGFloat, y: CGFloat, height h: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        s.draw(at: CGPoint(x: x + 2, y: y + (h - size.height) / 2))
    }

    private func drawBar(_ ctx: CGContext, x: CGFloat, y: CGFloat,
                         width w: CGFloat, height h: CGFloat,
                         level: Float, peak: Float) {
        // Trough.
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.fill(NSRect(x: x, y: y, width: w, height: h))

        let amberPos = CGFloat(Self.normalize(Self.amberDB))
        let redPos = CGFloat(Self.normalize(Self.redDB))
        let amberX = w * amberPos
        let redX = w * redPos

        let fillW = w * CGFloat(Self.normalizeAmplitude(level))
        if fillW > 0 {
            // Green segment.
            let endG = min(fillW, amberX)
            if endG > 0 {
                ctx.setFillColor(Self.greenColor.cgColor)
                ctx.fill(NSRect(x: x, y: y, width: endG, height: h))
            }
            // Amber segment.
            if fillW > amberX {
                let endA = min(fillW, redX)
                ctx.setFillColor(Self.amberColor.cgColor)
                ctx.fill(NSRect(x: x + amberX, y: y, width: endA - amberX, height: h))
            }
            // Red segment.
            if fillW > redX {
                ctx.setFillColor(Self.redColor.cgColor)
                ctx.fill(NSRect(x: x + redX, y: y, width: fillW - redX, height: h))
            }
        }

        // Zone dividers (subtle).
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(1)
        for px in [amberX, redX] {
            ctx.move(to: CGPoint(x: x + px, y: y))
            ctx.addLine(to: CGPoint(x: x + px, y: y + h))
        }
        ctx.strokePath()

        // Peak-hold marker.
        let peakRatio = Self.normalizeAmplitude(peak)
        if peakRatio > 0 {
            let peakX = x + w * CGFloat(peakRatio)
            let color: NSColor = peakRatio > Float(redPos) ? Self.redColor
                : peakRatio > Float(amberPos) ? Self.amberColor
                : Self.greenColor
            ctx.setFillColor(color.cgColor)
            ctx.fill(NSRect(x: peakX - 1, y: y, width: 2, height: h))
        }
    }

    private static func normalize(_ db: Float) -> Float {
        max(0, min(1, (db - minDB) / (maxDB - minDB)))
    }

    private static func normalizeAmplitude(_ amp: Float) -> Float {
        let db = 20.0 * log10f(max(amp, 1e-7))
        return normalize(db)
    }
}
