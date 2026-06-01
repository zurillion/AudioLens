import AppKit

@MainActor
final class PitchTimeView: NSView {

    private let audioEngine: AudioEngine

    private let semitoneStepper = NSStepper()
    private let semitoneLabel = NSTextField(labelWithString: "0 st")
    private let centSlider = NSSlider(value: 0, minValue: -100, maxValue: 100, target: nil, action: nil)
    private let centLabel = NSTextField(labelWithString: "0 cents")
    private let rateSlider = NSSlider(value: 1.0, minValue: 0.25, maxValue: 4.0, target: nil, action: nil)
    private let rateLabel = NSTextField(labelWithString: "1.00×")

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
        semitoneStepper.minValue = -24
        semitoneStepper.maxValue = 24
        semitoneStepper.increment = 1
        semitoneStepper.target = self
        semitoneStepper.action = #selector(semitoneChanged(_:))

        centSlider.target = self
        centSlider.action = #selector(centChanged(_:))
        centSlider.isContinuous = true

        rateSlider.target = self
        rateSlider.action = #selector(rateChanged(_:))
        rateSlider.isContinuous = true

        let semitoneRow = labeledRow(title: "Semitones", controls: [semitoneStepper, semitoneLabel])
        let centRow = labeledRow(title: "Cents", controls: [centSlider, centLabel])
        let rateRow = labeledRow(title: "Rate", controls: [rateSlider, rateLabel])

        let stack = NSStackView(views: [semitoneRow, centRow, rateRow])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ])
    }

    private func labeledRow(title: String, controls: [NSView]) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let stack = NSStackView(views: [label] + controls)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }

    @objc private func semitoneChanged(_ sender: NSStepper) {
        let semitones = sender.intValue
        semitoneLabel.stringValue = "\(semitones) st"
        applyPitch()
    }

    @objc private func centChanged(_ sender: NSSlider) {
        let cents = Int(sender.doubleValue.rounded())
        centLabel.stringValue = "\(cents) cents"
        applyPitch()
    }

    @objc private func rateChanged(_ sender: NSSlider) {
        let rate = sender.doubleValue
        rateLabel.stringValue = String(format: "%.2f×", rate)
        audioEngine.rate = Float(rate)
    }

    private func applyPitch() {
        let totalCents = Float(semitoneStepper.intValue * 100) + Float(centSlider.doubleValue)
        audioEngine.pitchCents = totalCents
    }
}
