import AppKit
import AVFoundation

@MainActor
final class TransportView: NSView {

    private let audioEngine: AudioEngine
    private let playButton = NSButton(title: "▶︎ Play", target: nil, action: nil)
    private let stopButton = NSButton(title: "■ Stop", target: nil, action: nil)
    private let loopButton = NSButton(checkboxWithTitle: "Loop", target: nil, action: nil)
    private let bookmarkButton = NSButton()
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    private let volumeSlider = NSSlider(value: 100, minValue: 0, maxValue: 200, target: nil, action: nil)
    private let volumeLabel = NSTextField(labelWithString: "100%")
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
        updateTimeLabel(currentFrame: audioEngine.currentFramePosition)
    }

    /// Called from the playhead timer; receives the current frame pre-computed
    /// by the caller so we don't query AVAudioPlayerNode.playerTime twice per
    /// tick (which used to trip AVFoundation's 32 Hz reporting rate-limit).
    func updatePlayheadDisplay(currentFrame: AVAudioFramePosition) {
        updateTimeLabel(currentFrame: currentFrame)
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
        loopButton.state = audioEngine.loopMode ? .on : .off

        bookmarkButton.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: "Add Bookmark")
        bookmarkButton.title = "+"
        bookmarkButton.imagePosition = .imageRight
        bookmarkButton.bezelStyle = .rounded
        bookmarkButton.target = self
        bookmarkButton.action = #selector(addBookmark(_:))
        bookmarkButton.toolTip = "Add a bookmark at the playhead (⌘B)"

        timeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged(_:))
        volumeSlider.isContinuous = true
        volumeSlider.doubleValue = Double(audioEngine.volume) * 100
        volumeSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        volumeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        volumeLabel.alignment = .right
        volumeLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        updateVolumeLabel()
        let volumeIcon = NSTextField(labelWithString: "🔊")

        let stack = NSStackView(views: [
            playButton, stopButton, loopButton, bookmarkButton, timeLabel,
            volumeIcon, volumeSlider, volumeLabel, statusLabel
        ])
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

    private func updateTimeLabel(currentFrame: AVAudioFramePosition) {
        let rate = audioEngine.sampleRate
        let current = Double(currentFrame) / rate
        let total = Double(audioEngine.totalFrames) / rate
        timeLabel.stringValue = "\(Self.formatTime(current)) / \(Self.formatTime(total))"
    }

    private func updateVolumeLabel() {
        volumeLabel.stringValue = "\(Int(volumeSlider.doubleValue.rounded()))%"
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        audioEngine.volume = Float(sender.doubleValue / 100.0)
        updateVolumeLabel()
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
        audioEngine.loopMode = (sender.state == .on)
    }

    @objc private func addBookmark(_ sender: NSButton) {
        audioEngine.addBookmarkAtPlayhead()
    }
}
