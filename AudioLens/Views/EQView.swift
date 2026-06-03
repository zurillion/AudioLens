import AppKit

@MainActor
final class EQView: NSView {

    private let audioEngine: AudioEngine
    private let bandSelector = NSSegmentedControl()
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    private let slidersStack = NSStackView()
    private var bandSliders: [NSSlider] = []

    init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.4).cgColor
        layer?.cornerRadius = 6
        setupSubviews()
        rebuildBands()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setupSubviews() {
        let bandsLabel = NSTextField(labelWithString: "Bands:")
        bandsLabel.font = .systemFont(ofSize: 11)

        bandSelector.segmentStyle = .rounded
        bandSelector.segmentCount = AudioEngine.supportedEQBandCounts.count
        for (i, count) in AudioEngine.supportedEQBandCounts.enumerated() {
            bandSelector.setLabel("\(count)", forSegment: i)
            bandSelector.setWidth(44, forSegment: i)
        }
        bandSelector.selectedSegment = AudioEngine.supportedEQBandCounts.firstIndex(of: audioEngine.eqBandCount) ?? 0
        bandSelector.target = self
        bandSelector.action = #selector(bandCountChanged(_:))

        resetButton.target = self
        resetButton.action = #selector(resetTapped(_:))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.toolTip = "Flatten all EQ bands to 0 dB."

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controlsRow = NSStackView(views: [bandsLabel, bandSelector, spacer, resetButton])
        controlsRow.orientation = .horizontal
        controlsRow.alignment = .centerY
        controlsRow.spacing = 8

        slidersStack.orientation = .horizontal
        slidersStack.distribution = .fillEqually
        slidersStack.alignment = .top
        slidersStack.spacing = 4

        let outer = NSStackView(views: [controlsRow, slidersStack])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 8
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)

        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            controlsRow.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
            controlsRow.trailingAnchor.constraint(equalTo: outer.trailingAnchor),
            slidersStack.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
            slidersStack.trailingAnchor.constraint(equalTo: outer.trailingAnchor),
        ])
    }

    /// Rebuilds the slider columns to match the engine's current band layout.
    private func rebuildBands() {
        for view in slidersStack.arrangedSubviews {
            slidersStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        bandSliders.removeAll()

        let frequencies = audioEngine.eqFrequencies
        let narrow = frequencies.count > 12   // hide labels on every column when dense
        for (index, freq) in frequencies.enumerated() {
            let slider = NSSlider(value: Double(audioEngine.eq.bands[index].gain),
                                  minValue: -24, maxValue: 24,
                                  target: self, action: #selector(bandChanged(_:)))
            slider.isVertical = true
            slider.tag = index
            slider.isContinuous = true
            bandSliders.append(slider)

            let showLabel = !narrow || index % 2 == 0
            let label = NSTextField(labelWithString: showLabel ? Self.formatFrequency(freq) : " ")
            label.alignment = .center
            label.font = .systemFont(ofSize: 9)

            let column = NSStackView(views: [slider, label])
            column.orientation = .vertical
            column.alignment = .centerX
            column.spacing = 3
            slidersStack.addArrangedSubview(column)
        }
    }

    // MARK: - Actions

    @objc private func bandChanged(_ sender: NSSlider) {
        let bandIndex = sender.tag
        guard bandIndex < audioEngine.eq.bands.count else { return }
        audioEngine.eq.bands[bandIndex].gain = Float(sender.doubleValue)
    }

    @objc private func bandCountChanged(_ sender: NSSegmentedControl) {
        let seg = sender.selectedSegment
        guard seg >= 0, seg < AudioEngine.supportedEQBandCounts.count else { return }
        audioEngine.setEQBandCount(AudioEngine.supportedEQBandCounts[seg])
        rebuildBands()
    }

    @objc private func resetTapped(_ sender: NSButton) {
        audioEngine.resetEQ()
        for slider in bandSliders {
            slider.doubleValue = 0
        }
    }

    private static func formatFrequency(_ frequency: Float) -> String {
        if frequency >= 1000 {
            let k = frequency / 1000
            return k >= 10 ? String(format: "%.0fk", k) : String(format: "%.1fk", k)
        }
        return String(format: "%.0f", frequency)
    }
}
