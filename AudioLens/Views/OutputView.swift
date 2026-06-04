import AppKit

/// Output / mixing controls. Row 1: master volume, stereo pan with a
/// Balance/Pan mode selector, and a "Mono" toggle. Row 2: an optional
/// clip-safe output stage (peak limiter, with an extra tanh saturator and
/// Drive knob in Saturator mode).
@MainActor
final class OutputView: NSView {

    private let audioEngine: AudioEngine

    private let volumeSlider = NSSlider(value: 100, minValue: 0, maxValue: 200, target: nil, action: nil)
    private let volumeLabel = NSTextField(labelWithString: "100%")
    private let panSlider = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let panLabel = NSTextField(labelWithString: "C")
    private let panModeControl = NSSegmentedControl(
        labels: ["Balance", "Pan"], trackingMode: .selectOne, target: nil, action: nil)
    private let monoCheckbox = NSButton(checkboxWithTitle: "Mono", target: nil, action: nil)

    private let stageCheckbox = NSButton(checkboxWithTitle: "Clip-safe output", target: nil, action: nil)
    private let stageModeControl = NSSegmentedControl(
        labels: ["Limiter", "Saturator"], trackingMode: .selectOne, target: nil, action: nil)
    private let driveSlider = NSSlider(value: 2, minValue: 1, maxValue: 8, target: nil, action: nil)
    private let driveLabel = NSTextField(labelWithString: "×2.0")

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
        let row1 = makeMixRow()
        let row2 = makeStageRow()

        let outer = NSStackView(views: [row1, row2])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 8
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)

        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            outer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            outer.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        updateStageEnablement()
    }

    private func makeMixRow() -> NSView {
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

        panModeControl.target = self
        panModeControl.action = #selector(panModeChanged(_:))
        panModeControl.selectedSegment = (audioEngine.panMode == .pan) ? 1 : 0
        panModeControl.toolTip =
            "Balance: pan mutes the opposite channel.  Pan: it folds in instead (no content lost)."

        monoCheckbox.target = self
        monoCheckbox.action = #selector(monoChanged(_:))
        monoCheckbox.state = audioEngine.isMono ? .on : .off
        monoCheckbox.toolTip = "Sum left and right to a single mono signal"
        panModeControl.isEnabled = !audioEngine.isMono

        let row = NSStackView(views: [
            volumeIcon, volumeSlider, volumeLabel,
            verticalSeparator(),
            panTitle, lLabel, panSlider, rLabel, panLabel, panModeControl,
            monoCheckbox,
        ])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        return row
    }

    private func makeStageRow() -> NSView {
        stageCheckbox.target = self
        stageCheckbox.action = #selector(stageEnabledChanged(_:))
        stageCheckbox.state = audioEngine.outputStageEnabled ? .on : .off
        stageCheckbox.toolTip = "Insert a final stage so the output can never clip."

        stageModeControl.target = self
        stageModeControl.action = #selector(stageModeChanged(_:))
        stageModeControl.selectedSegment = (audioEngine.outputStageMode == .saturator) ? 1 : 0
        stageModeControl.toolTip =
            "Limiter: transparent ceiling.  Saturator: adds tanh warmth/loudness (BOOM-style)."

        driveSlider.target = self
        driveSlider.action = #selector(driveChanged(_:))
        driveSlider.isContinuous = true
        driveSlider.doubleValue = Double(audioEngine.saturationDrive)
        driveSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        driveLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        driveLabel.alignment = .right
        driveLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        updateDriveLabel()

        let row = NSStackView(views: [
            stageCheckbox,
            verticalSeparator(),
            stageModeControl,
            NSTextField(labelWithString: "Drive"), driveSlider, driveLabel,
        ])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        return row
    }

    private func verticalSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 20).isActive = true
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }

    // MARK: - Actions

    @objc private func volumeChanged(_ sender: NSSlider) {
        audioEngine.volume = Float(sender.doubleValue / 100.0)
        updateVolumeLabel()
    }

    @objc private func panChanged(_ sender: NSSlider) {
        if abs(sender.doubleValue) < 0.03 { sender.doubleValue = 0 }
        audioEngine.pan = Float(sender.doubleValue)
        updatePanLabel()
    }

    @objc private func panModeChanged(_ sender: NSSegmentedControl) {
        audioEngine.panMode = (sender.selectedSegment == 1) ? .pan : .balance
    }

    @objc private func monoChanged(_ sender: NSButton) {
        audioEngine.isMono = (sender.state == .on)
        panModeControl.isEnabled = (sender.state != .on)
    }

    @objc private func stageEnabledChanged(_ sender: NSButton) {
        audioEngine.outputStageEnabled = (sender.state == .on)
        updateStageEnablement()
    }

    @objc private func stageModeChanged(_ sender: NSSegmentedControl) {
        audioEngine.outputStageMode = (sender.selectedSegment == 1) ? .saturator : .limiter
        updateStageEnablement()
    }

    @objc private func driveChanged(_ sender: NSSlider) {
        audioEngine.saturationDrive = Float(sender.doubleValue)
        updateDriveLabel()
    }

    // MARK: - Display

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

    private func updateDriveLabel() {
        driveLabel.stringValue = String(format: "×%.1f", driveSlider.doubleValue)
    }

    /// Mode selector active only when the stage is on; Drive only in Saturator.
    private func updateStageEnablement() {
        let on = (stageCheckbox.state == .on)
        let saturator = (stageModeControl.selectedSegment == 1)
        stageModeControl.isEnabled = on
        driveSlider.isEnabled = on && saturator
        driveLabel.textColor = (on && saturator) ? .labelColor : .disabledControlTextColor
    }
}
