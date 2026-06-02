import AppKit

@MainActor
final class TransportView: NSView {

    private let audioEngine: AudioEngine
    private let playButton = NSButton(title: "▶︎ Play", target: nil, action: nil)
    private let stopButton = NSButton(title: "■ Stop", target: nil, action: nil)
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
    }

    private func setupSubviews() {
        playButton.target = self
        playButton.action = #selector(togglePlay(_:))
        stopButton.target = self
        stopButton.action = #selector(stop(_:))

        let stack = NSStackView(views: [playButton, stopButton, statusLabel])
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
}
