import AppKit

@MainActor
final class MainViewController: NSViewController {

    private let audioEngine: AudioEngine
    private let waveformView: WaveformView
    private let transportView: TransportView
    private let eqView: EQView
    private let pitchTimeView: PitchTimeView

    init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
        self.waveformView = WaveformView()
        self.transportView = TransportView(audioEngine: audioEngine)
        self.eqView = EQView(audioEngine: audioEngine)
        self.pitchTimeView = PitchTimeView(audioEngine: audioEngine)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let waveContainer = waveformView
        let transport = transportView
        let pitchTime = pitchTimeView
        let eq = eqView

        for v in [waveContainer, transport, pitchTime, eq] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }

        NSLayoutConstraint.activate([
            waveContainer.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            waveContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            waveContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            waveContainer.heightAnchor.constraint(equalToConstant: 220),

            transport.topAnchor.constraint(equalTo: waveContainer.bottomAnchor, constant: 12),
            transport.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            transport.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            transport.heightAnchor.constraint(equalToConstant: 48),

            pitchTime.topAnchor.constraint(equalTo: transport.bottomAnchor, constant: 12),
            pitchTime.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            pitchTime.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            pitchTime.heightAnchor.constraint(equalToConstant: 140),

            eq.topAnchor.constraint(equalTo: pitchTime.bottomAnchor, constant: 12),
            eq.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            eq.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            eq.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])

        self.view = root
    }

    func didLoadAudio() {
        if let buffer = audioEngine.fullBuffer {
            waveformView.setBuffer(buffer)
        }
        transportView.refresh()
    }
}
