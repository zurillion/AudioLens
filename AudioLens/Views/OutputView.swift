import AppKit

/// Output / mixing controls: master volume, stereo pan (balance), and a "Mono"
/// toggle that sums L+R. Pan stays active in mono mode, where it positions the
/// summed signal with an equal-power law.
@MainActor
final class OutputView: NSView {

    private let audioEngine: AudioEngine

    private let volumeSlider = NSSlider(value: 100, minValue: 0, maxValue: 200, target: nil, action: nil)
    private let volumeLabel = NSTextField(labelWithString: "100%")
    private let panSlider = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let panLabel = NSTextField(labelWithString: "C")
    private let monoCheckbox = NSButton(checkboxWithTitle: "Mono", target: nil, action: nil)

    init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
        super.init(frame: .zero)
        wantsLayer = true
        setupSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setupSubviews() {
        let volumeIcon = NSTextField(labelWithString: "🔊")

        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged(_:))
        volumeSlider.isContinuous = true
        volumeSlider.doubleValue = Double(audioEngine.volume) * 100
        volumeSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        volumeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        volumeLabel.alignment = .right
        volumeLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        updateVolumeLabel()

        let panTitle = NSTextField(labelWithString: "Pan")
        let lLabel = NSTextField(labelWithString: "L")
        let rLabel = NSTextField(labelWithString: "R")
        for label in [lLabel, rLabel] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
        }
        panSlider.target = self
        panSlider.action = #selector(panChanged(_:))
        panSlider.isContinuous = true
        panSlider.doubleValue = Double(audioEngine.pan)
        panSlider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        panSlider.toolTip = "Stereo pan / balance (snaps to center near the middle)"
        panLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        panLabel.alignment = .right
        panLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        updatePanLabel()

        monoCheckbox.target = self
        monoCheckbox.action = #selector(monoChanged(_:))
        monoCheckbox.state = audioEngine.isMono ? .on : .off
        monoCheckbox.toolTip = "Sum left and right to a single mono signal"

        // A thin spacer separates the volume group from the pan group.
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let stack = NSStackView(views: [
            volumeIcon, volumeSlider, volumeLabel,
            separator,
            panTitle, lLabel, panSlider, rLabel, panLabel,
            monoCheckbox,
        ])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // MARK: - Actions

    @objc private func volumeChanged(_ sender: NSSlider) {
        audioEngine.volume = Float(sender.doubleValue / 100.0)
        updateVolumeLabel()
    }

    @objc private func panChanged(_ sender: NSSlider) {
        // Snap to dead center near zero so a centred image is easy to hit.
        if abs(sender.doubleValue) < 0.03 { sender.doubleValue = 0 }
        audioEngine.pan = Float(sender.doubleValue)
        updatePanLabel()
    }

    @objc private func monoChanged(_ sender: NSButton) {
        audioEngine.isMono = (sender.state == .on)
    }

    private func updateVolumeLabel() {
        volumeLabel.stringValue = "\(Int(volumeSlider.doubleValue.rounded()))%"
    }

    private func updatePanLabel() {
        let p = panSlider.doubleValue
        if abs(p) < 0.005 {
            panLabel.stringValue = "C"
        } else if p < 0 {
            panLabel.stringValue = "L\(Int((-p * 100).rounded()))"
        } else {
            panLabel.stringValue = "R\(Int((p * 100).rounded()))"
        }
    }
}
