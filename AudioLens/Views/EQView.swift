import AppKit

@MainActor
final class EQView: NSView {

    private let audioEngine: AudioEngine
    private var bandSliders: [NSSlider] = []

    init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.4).cgColor
        layer?.cornerRadius = 6
        setupSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setupSubviews() {
        let frequencies = AudioEngine.eqBandFrequencies
        let columns: [NSView] = frequencies.enumerated().map { index, freq in
            let slider = NSSlider(value: 0, minValue: -24, maxValue: 24, target: self, action: #selector(bandChanged(_:)))
            slider.isVertical = true
            slider.tag = index
            slider.isContinuous = true
            bandSliders.append(slider)

            let label = NSTextField(labelWithString: Self.formatFrequency(freq))
            label.alignment = .center
            label.font = .systemFont(ofSize: 10)

            let column = NSStackView(views: [slider, label])
            column.orientation = .vertical
            column.alignment = .centerX
            column.spacing = 4
            return column
        }

        let stack = NSStackView(views: columns)
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .top
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @objc private func bandChanged(_ sender: NSSlider) {
        let bandIndex = sender.tag
        guard bandIndex < audioEngine.eq.bands.count else { return }
        audioEngine.eq.bands[bandIndex].gain = Float(sender.doubleValue)
    }

    private static func formatFrequency(_ frequency: Float) -> String {
        if frequency >= 1000 {
            return String(format: "%.0fk", frequency / 1000)
        }
        return String(format: "%.0f", frequency)
    }
}
