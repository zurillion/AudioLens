import AppKit

@MainActor
final class MainViewController: NSViewController {

    private let audioEngine: AudioEngine
    private let waveformView: WaveformView
    private let vuMeterView: VUMeterView
    private let transportView: TransportView
    private let outputView: OutputView
    private let eqView: EQView
    private let pitchTimeView: PitchTimeView
    private var playheadTimer: Timer?
    private var lastTickTime: TimeInterval = 0

    /// Set by the window controller; invoked when a file is dropped on the
    /// window.
    var onOpenFile: ((URL) -> Void)?

    init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
        self.waveformView = WaveformView()
        self.vuMeterView = VUMeterView()
        self.transportView = TransportView(audioEngine: audioEngine)
        self.outputView = OutputView(audioEngine: audioEngine)
        self.eqView = EQView(audioEngine: audioEngine)
        self.pitchTimeView = PitchTimeView(audioEngine: audioEngine)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = FileDropView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        root.onDrop = { [weak self] url in self?.onOpenFile?(url) }

        let waveContainer = waveformView
        let vuMeter = vuMeterView
        let transport = transportView
        let output = outputView
        let pitchTime = pitchTimeView
        let eq = eqView

        for v in [waveContainer, vuMeter, transport, output, pitchTime, eq] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }

        NSLayoutConstraint.activate([
            waveContainer.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            waveContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            waveContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            waveContainer.heightAnchor.constraint(equalToConstant: 260),

            vuMeter.topAnchor.constraint(equalTo: waveContainer.bottomAnchor, constant: 8),
            vuMeter.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            vuMeter.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            vuMeter.heightAnchor.constraint(equalToConstant: 28),

            transport.topAnchor.constraint(equalTo: vuMeter.bottomAnchor, constant: 8),
            transport.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            transport.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            transport.heightAnchor.constraint(equalToConstant: 48),

            output.topAnchor.constraint(equalTo: transport.bottomAnchor, constant: 12),
            output.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            output.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            output.heightAnchor.constraint(equalToConstant: 76),

            pitchTime.topAnchor.constraint(equalTo: output.bottomAnchor, constant: 12),
            pitchTime.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            pitchTime.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            pitchTime.heightAnchor.constraint(equalToConstant: 140),

            eq.topAnchor.constraint(equalTo: pitchTime.bottomAnchor, constant: 12),
            eq.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            eq.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            eq.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])

        self.view = root

        waveformView.onRegionSelected = { [weak self] start, length in
            guard let self else { return }
            self.audioEngine.setSelection(
                .region(start: start, length: length, loops: self.audioEngine.loopMode)
            )
            self.waveformView.selection = self.audioEngine.selection
        }
        waveformView.onSeek = { [weak self] frame in
            guard let self else { return }
            self.audioEngine.seek(toFrame: frame)
            self.waveformView.selection = self.audioEngine.selection
        }
        waveformView.onLoopBoundsChanged = { [weak self] start, end in
            self?.audioEngine.setRegionBounds(start: start, end: end)
        }
        waveformView.onTrimChanged = { [weak self] start, end in
            self?.audioEngine.setTrim(start: start, end: end)
        }
        waveformView.onBookmarkMoved = { [weak self] from, to in
            self?.audioEngine.moveBookmark(from: from, to: to)
        }
        waveformView.onBookmarkDeleted = { [weak self] frame in
            self?.audioEngine.removeBookmark(at: frame)
        }
        waveformView.onBookmarkRenameRequested = { [weak self] frame in
            guard let self else { return }
            BookmarkRenamePrompt.present(in: self.view.window, engine: self.audioEngine, frame: frame)
        }

        audioEngine.onBookmarksChanged = { [weak self] in
            guard let self else { return }
            self.waveformView.bookmarks = self.audioEngine.bookmarks.map { $0.frame }
        }

        transportView.onZoomIn = { [weak self] in self?.waveformView.zoomInCentered() }
        transportView.onZoomOut = { [weak self] in self?.waveformView.zoomOutCentered() }
        transportView.onFollowTapped = { [weak self] in self?.waveformView.toggleAutoFollow() }
        waveformView.onAutoFollowChanged = { [weak self] on in
            self?.transportView.setFollowPlayhead(on: on)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startPlayheadTimer()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        playheadTimer?.invalidate()
        playheadTimer = nil
    }

    private func startPlayheadTimer() {
        playheadTimer?.invalidate()
        // 24 Hz: smooth enough for the playhead, comfortably under
        // AVFoundation's internal 32 Hz reporting rate-limit. We'll switch to
        // CADisplayLink (vsync-locked) when the Metal waveform renderer lands.
        playheadTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            // The timer fires on the main run loop; assume the isolation rather
            // than hopping through a Task each tick.
            MainActor.assumeIsolated { self?.refreshPlayhead() }
        }
    }

    private func refreshPlayhead() {
        // Reconcile transport state in case playback reached its natural end on
        // the audio thread, then read the playhead once and fan it out.
        audioEngine.reconcile()
        let frame = audioEngine.currentFramePosition
        waveformView.playheadFrame = frame
        transportView.updatePlayheadDisplay(currentFrame: frame)

        // VU meter: pull the peaks the audio tap has accumulated since the
        // previous tick, scaled by the real elapsed time so ballistic decay is
        // tick-rate independent.
        let now = CFAbsoluteTimeGetCurrent()
        let dt: TimeInterval = lastTickTime > 0 ? max(0.001, now - lastTickTime) : 1.0 / 24.0
        lastTickTime = now
        let peaks = audioEngine.consumePeaks()
        vuMeterView.update(leftPeak: peaks.left, rightPeak: peaks.right, deltaTime: dt)
    }

    /// Called the moment a load begins (before decode) so the preview shows
    /// "Loading…" and the previous waveform is cleared right away.
    func willBeginLoading() {
        waveformView.beginLoading()
        vuMeterView.reset()
    }

    /// Called if the load fails, to clear the "Loading…" indicator.
    func didFailLoading() {
        waveformView.cancelLoading()
    }

    func didLoadAudio() {
        if let buffer = audioEngine.fullBuffer {
            waveformView.setBuffer(buffer, url: audioEngine.sourceURL)
            waveformView.trimStartFrame = audioEngine.trimStart
            waveformView.trimEndFrame = audioEngine.trimEnd
        }
        transportView.refresh()
        vuMeterView.reset()
    }
}
