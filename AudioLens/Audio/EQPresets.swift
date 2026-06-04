import Foundation

/// A frequency-shaped graphic-EQ preset, defined as `(frequency, gain dB)`
/// control points. The gain for each band is sampled by interpolating these
/// points in the log-frequency domain, so the *same* preset maps cleanly onto
/// any band count (10 / 20 / 30) without per-layout tables.
struct EQPreset: Sendable {
    let name: String
    /// Control points, ascending by frequency.
    let points: [(frequency: Double, gain: Float)]

    /// Interpolated gain (dB) at `frequency`, linear in log2(frequency), held
    /// flat beyond the outermost control points.
    func gain(atFrequency frequency: Double) -> Float {
        guard let first = points.first, let last = points.last else { return 0 }
        if frequency <= first.frequency { return first.gain }
        if frequency >= last.frequency { return last.gain }
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            if frequency <= b.frequency {
                let t = (log2(frequency) - log2(a.frequency)) /
                        (log2(b.frequency) - log2(a.frequency))
                return a.gain + Float(t) * (b.gain - a.gain)
            }
        }
        return last.gain
    }
}

extension EQPreset {
    /// Ten generally-useful tonal presets, ordered for the EQ menu.
    static let all: [EQPreset] = [
        EQPreset(name: "Bass Boost", points: [
            (31.5, 9), (63, 8), (125, 6), (250, 3), (500, 1), (1000, 0), (16000, 0),
        ]),
        EQPreset(name: "Bass Cut", points: [
            (31.5, -12), (63, -9), (125, -6), (250, -3), (500, -1), (1000, 0), (16000, 0),
        ]),
        EQPreset(name: "Treble Boost", points: [
            (250, 0), (1000, 0), (2000, 2), (4000, 5), (8000, 7), (16000, 8),
        ]),
        EQPreset(name: "Vocal Presence", points: [
            (63, -2), (125, -1), (250, 0), (500, 1), (1000, 3),
            (2000, 4), (3150, 4), (5000, 2), (8000, 0), (16000, 0),
        ]),
        EQPreset(name: "Loudness (V-Shape)", points: [
            (31.5, 8), (63, 7), (125, 4), (250, 1), (500, -2),
            (1000, -3), (2000, -2), (4000, 1), (8000, 5), (16000, 7),
        ]),
        EQPreset(name: "Warm", points: [
            (63, 2), (125, 4), (250, 3), (500, 1), (1000, 0),
            (2000, -1), (4000, -2), (8000, -4), (16000, -5),
        ]),
        EQPreset(name: "Bright / Air", points: [
            (1000, 0), (2000, 1), (4000, 3), (8000, 5), (12500, 6), (16000, 8),
        ]),
        EQPreset(name: "Lo-Fi / Telephone", points: [
            (31.5, -24), (63, -20), (125, -12), (250, -4), (500, 2), (1000, 4),
            (2000, 3), (3150, 0), (4000, -6), (8000, -20), (16000, -24),
        ]),
        EQPreset(name: "Podcast / Speech", points: [
            (31.5, -14), (63, -8), (125, -3), (250, 0), (500, 1), (1000, 2),
            (2000, 3), (4000, 2), (6300, -2), (8000, -3), (16000, -5),
        ]),
        EQPreset(name: "Acoustic", points: [
            (63, 1), (125, 2), (250, 0), (500, -1), (1000, 0),
            (2000, 1), (4000, 3), (8000, 3), (16000, 2),
        ]),
    ]
}
