import AppKit

@MainActor
final class EQView: NSView {

    private let audioEngine: AudioEngine
    private let bandSelector = NSSegmentedControl()
    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: true)
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

        // Pull-down menu of tonal presets. The first item is the button's
        // title (pull-down convention); the rest apply a preset on selection.
        let presetMenu = NSMenu()
        presetMenu.addItem(withTitle: "Presets", action: nil, keyEquivalent: "")
        for (i, preset) in AudioEngine.eqPresets.enumerated() {
            let item = NSMenuItem(title: preset.name,
                                  action: #selector(presetSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            presetMenu.addItem(item)
        }
        presetPopup.menu = presetMenu
        presetPopup.controlSize = .small
        presetPopup.toolTip = "Apply a tonal preset (works at any band count)."

        resetButton.target = self
        resetButton.action = #selector(resetTapped(_:))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.toolTip = "Flatten all EQ bands to 0 dB."

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controlsRow = NSStackView(views: [bandsLabel, bandSelector, presetPopup, spacer, resetButton])
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
        // Every band is labeled. With many bands, horizontal labels would
        // overlap, so they're drawn vertically (rotated) past a threshold.
        let dense = frequencies.count > 12
        for (index, freq) in frequencies.enumerated() {
            let slider = NSSlider(value: Double(audioEngine.eq.bands[index].gain),
                                  minValue: -24, maxValue: 24,
                                  target: self, action: #selector(bandChanged(_:)))
            slider.isVertical = true
            slider.tag = index
            slider.isContinuous = true
            bandSliders.append(slider)

            let text = Self.formatFrequency(freq)
            let labelView: NSView
            if dense {
                labelView = VerticalTextLabel(string: text,
                                              font: .systemFont(ofSize: 9),
                                              color: .labelColor)
            } else {
                let label = NSTextField(labelWithString: text)
                label.alignment = .center
                label.font = .systemFont(ofSize: 9)
                labelView = label
            }

            let column = NSStackView(views: [slider, labelView])
            column.orientation = .vertical
            column.alignment = .centerX
            column.spacing = 3
            slidersStack.addArrangedSubview(column)
        }
    }

    /// Pull every slider's position from the engine (after a preset / band-count
    /// change), so the UI reflects the gains actually applied.
    private func syncSlidersToEngine() {
        for slider in bandSliders where slider.tag < audioEngine.eq.bands.count {
            slider.doubleValue = Double(audioEngine.eq.bands[slider.tag].gain)
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

    @objc private func presetSelected(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx >= 0, idx < AudioEngine.eqPresets.count else { return }
        audioEngine.applyEQPreset(AudioEngine.eqPresets[idx])
        syncSlidersToEngine()
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

/// A label that draws its text rotated 90° (reading bottom-to-top), so dense
/// EQ-band labels fit in a narrow column without overlapping their neighbours.
private final class VerticalTextLabel: NSView {
    private let attributed: NSAttributedString
    private let textSize: NSSize

    init(string: String, font: NSFont, color: NSColor) {
        attributed = NSAttributedString(string: string,
                                        attributes: [.font: font, .foregroundColor: color])
        textSize = attributed.size()
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // The on-screen footprint is the text box rotated 90°: width/height swap.
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(textSize.height), height: ceil(textSize.width))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        // Move to the bottom-right corner, rotate 90° CCW; the string then runs
        // upward and fills the (swapped) bounds.
        ctx.translateBy(x: bounds.width, y: 0)
        ctx.rotate(by: .pi / 2)
        attributed.draw(at: .zero)
        ctx.restoreGState()
    }
}
