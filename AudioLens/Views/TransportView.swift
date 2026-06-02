import AppKit
import AVFoundation

@MainActor
final class TransportView: NSView {

    private let audioEngine: AudioEngine
    private let playButton = NSButton(title: "▶︎ Play", target: nil, action: nil)
    private let stopButton = NSButton(title: "■ Stop", target: nil, action: nil)
    private let loopButton = NSButton(checkboxWithTitle: "Loop", target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    private let statusLabel = NSTextField(labelWithString: "No file loaded")

    init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
        super.init(frame: .zero)
        wantsLayer = true
        setupSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func refresh() {
        statusLabel.stringValue = audioEngine.sourceURL?.lastPathComponent ?? "No file loaded"
        loopButton.state = audioEngine.loopMode ? .on : .off
        updateTimeLabel()
    }

    func updatePlayheadDisplay() {
        updateTimeLabel()
        // Keep the play button label in sync with engine state in case the
        // user paused via another path (e.g. playback finished).
        switch audioEngine.state {
        case .playing:
            playButton.title = "❚❚ Pause"
        case .paused, .loaded, .idle:
            playButton.title = "▶︎ Play"
        }
    }

    private func setupSubviews() {
        playButton.target = self
        playButton.action = #selector(togglePlay(_:))
        stopButton.target = self
        stopButton.action = #selector(stop(_:))
        loopButton.target = self
        loopButton.action = #selector(toggleLoop(_:))

        timeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        let stack = NSStackView(views: [playButton, stopButton, loopButton, timeLabel, statusLabel])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func updateTimeLabel() {
        let rate = audioEngine.sampleRate
        let current = Double(audioEngine.currentFramePosition) / rate
        let total = Double(audioEngine.totalFrames) / rate
        timeLabel.stringValue = "\(Self.formatTime(current)) / \(Self.formatTime(total))"
    }

    private static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds.rounded(.down))
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    @objc private func togglePlay(_ sender: NSButton) {
        switch audioEngine.state {
        case .playing:
            audioEngine.pause()
            playButton.title = "▶︎ Play"
        case .loaded, .paused:
            audioEngine.play()
            playButton.title = "❚❚ Pause"
        case .idle:
            break
        }
    }

    @objc private func stop(_ sender: NSButton) {
        audioEngine.stop()
        playButton.title = "▶︎ Play"
    }

    @objc private func toggleLoop(_ sender: NSButton) {
        let on = (sender.state == .on)
        AudioLog.log("TransportView.toggleLoop -> \(on)")
        audioEngine.loopMode = on
    }
}
