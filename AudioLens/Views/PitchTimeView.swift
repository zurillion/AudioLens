import AppKit

@MainActor
final class PitchTimeView: NSView {

    private let audioEngine: AudioEngine

    private let tuningStepper = NSStepper()
    private let tuningLabel = NSTextField(labelWithString: "440.00 Hz")
    private let semitoneStepper = NSStepper()
    private let semitoneLabel = NSTextField(labelWithString: "0 st")
    private let centSlider = NSSlider(value: 0, minValue: -100, maxValue: 100, target: nil, action: nil)
    private let centLabel = NSTextField(labelWithString: "0.0 cents")
    private let rateSlider = NSSlider(value: 1.0, minValue: 0.25, maxValue: 4.0, target: nil, action: nil)
    private let rateLabel = NSTextField(labelWithString: "1.00×")
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)

    /// Reference frequency we measure the tuning against (A4).
    private static let referenceHz: Double = 440.0

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
        // The tuning range mirrors the ±24 semitone range, so a semitone push
        // that takes the equivalent Hz to ~110 (A2) or ~1760 (A6) still has a
        // valid display position.
        tuningStepper.minValue = 110.0
        tuningStepper.maxValue = 1760.0
        tuningStepper.increment = 0.5
        tuningStepper.doubleValue = Self.referenceHz
        tuningStepper.target = self
        tuningStepper.action = #selector(tuningChanged(_:))

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

        resetButton.target = self
        resetButton.action = #selector(resetPitchAndRate(_:))
        resetButton.bezelStyle = .rounded
        resetButton.toolTip = "Restore tuning to 440 Hz, pitch to 0, and rate to 1.00×."

        for label in [tuningLabel, semitoneLabel, centLabel, rateLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }

        let tuningRow = labeledRow(title: "Tuning (A4)", controls: [tuningStepper, tuningLabel])
        let semitoneRow = labeledRow(title: "Semitones", controls: [semitoneStepper, semitoneLabel])
        let centRow = labeledRow(title: "Cents", controls: [centSlider, centLabel])
        let rateRow = labeledRow(title: "Rate", controls: [rateSlider, rateLabel, resetButton])

        let stack = NSStackView(views: [tuningRow, semitoneRow, centRow, rateRow])
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
        label.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let stack = NSStackView(views: [label] + controls)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }

    // MARK: - Actions

    /// All three pitch controls (tuning Hz, semitones, fine cents) are views
    /// of the same total pitch offset. Each handler computes the new total
    /// and routes through `applyTotalCents`, which writes the engine and
    /// refreshes the other displays. `source` controls how aggressively the
    /// semis/fine pair is renormalised — a tuning change canonicalises them
    /// (semis = round, fine = residual); semis/fine edits leave the other
    /// alone so the user keeps the value they entered.
    @objc private func tuningChanged(_ sender: NSStepper) {
        let hz = sender.doubleValue
        let totalCents = 1200.0 * log2(hz / Self.referenceHz)
        applyTotalCents(totalCents, source: .tuning)
    }

    @objc private func semitoneChanged(_ sender: NSStepper) {
        let totalCents = Double(sender.integerValue) * 100.0 + centSlider.doubleValue
        applyTotalCents(totalCents, source: .semitone)
    }

    @objc private func centChanged(_ sender: NSSlider) {
        let totalCents = Double(semitoneStepper.integerValue) * 100.0 + sender.doubleValue
        applyTotalCents(totalCents, source: .cents)
    }

    @objc private func rateChanged(_ sender: NSSlider) {
        let rate = sender.doubleValue
        rateLabel.stringValue = String(format: "%.2f×", rate)
        audioEngine.rate = Float(rate)
    }

    @objc private func resetPitchAndRate(_ sender: NSButton) {
        // Push the engine first, then bring every control back to its
        // default display state.
        audioEngine.pitchCents = 0
        audioEngine.rate = 1.0

        tuningStepper.doubleValue = Self.referenceHz
        tuningLabel.stringValue = String(format: "%.2f Hz", Self.referenceHz)
        semitoneStepper.integerValue = 0
        semitoneLabel.stringValue = "0 st"
        centSlider.doubleValue = 0
        centLabel.stringValue = "0.0 cents"
        rateSlider.doubleValue = 1.0
        rateLabel.stringValue = "1.00×"
    }

    // MARK: - Synchronisation

    private enum ChangeSource {
        case tuning, semitone, cents
    }

    private func applyTotalCents(_ totalCents: Double, source: ChangeSource) {
        audioEngine.pitchCents = Float(totalCents)

        let hz = Self.referenceHz * pow(2.0, totalCents / 1200.0)
        tuningStepper.doubleValue = hz
        tuningLabel.stringValue = String(format: "%.2f Hz", hz)

        switch source {
        case .tuning:
            // Renormalise into canonical (round-to-nearest semitone, residual cents).
            let semis = max(-24, min(24, Int((totalCents / 100.0).rounded(.toNearestOrEven))))
            let fine = totalCents - Double(semis) * 100.0
            semitoneStepper.integerValue = semis
            semitoneLabel.stringValue = "\(semis) st"
            centSlider.doubleValue = fine
            centLabel.stringValue = String(format: "%.1f cents", fine)
        case .semitone:
            semitoneLabel.stringValue = "\(semitoneStepper.integerValue) st"
        case .cents:
            centLabel.stringValue = String(format: "%.1f cents", centSlider.doubleValue)
        }
    }
}
