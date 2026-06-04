import AppKit
import AVFoundation

@MainActor
final class TransportView: NSView {

    private let audioEngine: AudioEngine
    private let playButton = NSButton(title: "▶︎ Play", target: nil, action: nil)
    private let stopButton = NSButton(title: "■ Stop", target: nil, action: nil)
    private let loopButton = NSButton(checkboxWithTitle: "Loop", target: nil, action: nil)
    private let bookmarkButton = NSButton()
    private let bookmarksPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    private let zoomOutButton = NSButton()
    private let zoomInButton = NSButton()
    private let followButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "No file loaded")
    private let fileInfoLabel = NSTextField(labelWithString: "")

    /// Wired by MainViewController to drive the waveform's zoom / follow.
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onFollowTapped: (() -> Void)?

    /// Cached so the follow button can refresh its background on theme change
    /// without needing a state push from the WaveformView.
    private var followIsOn = true
    /// The notification callback runs in a nonisolated context; storing the
    /// token as `nonisolated(unsafe)` lets the nonisolated `deinit` read it
    /// (NotificationCenter.removeObserver is itself thread-safe).
    private nonisolated(unsafe) var themeObserver: (any NSObjectProtocol)?

    /// Two-tone follow-button foreground. The "on" background comes from the
    /// current theme (ThemeManager.followOnColor) and is applied in
    /// setFollowPlayhead, so a theme switch updates the lit chip live.
    private static let followOnFg = NSColor.white
    private static let followOffFg = NSColor.tertiaryLabelColor

    init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
        super.init(frame: .zero)
        wantsLayer = true
        setupSubviews()
        themeObserver = NotificationCenter.default.addObserver(
            forName: .themeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            // queue: .main runs us on the main thread, but the closure is
            // typed as nonisolated — hop into MainActor isolation explicitly.
            MainActor.assumeIsolated { self?.applyTheme() }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    func refresh() {
        statusLabel.stringValue = audioEngine.sourceURL?.lastPathComponent ?? "No file loaded"
        fileInfoLabel.stringValue = audioEngine.fileInfo?.summary ?? ""
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
        // Fixed width so toggling "Play" / "Pause" doesn't reflow the row.
        playButton.widthAnchor.constraint(equalToConstant: 88).isActive = true
        stopButton.target = self
        stopButton.action = #selector(stop(_:))
        loopButton.target = self
        loopButton.action = #selector(toggleLoop(_:))
        loopButton.state = audioEngine.loopMode ? .on : .off

        statusLabel.textColor = ThemeManager.shared.filenameColor

        bookmarkButton.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: "Add Bookmark")
        bookmarkButton.title = "+"
        bookmarkButton.imagePosition = .imageRight
        bookmarkButton.bezelStyle = .rounded
        bookmarkButton.target = self
        bookmarkButton.action = #selector(addBookmark(_:))
        bookmarkButton.toolTip = "Add a bookmark at the playhead (⌘B)"

        // Pull-down popup: its menu is rebuilt each time it opens, via the
        // delegate. Items target nil and travel the responder chain to
        // MainWindowController, identical to the menu-bar Bookmarks menu.
        let popupMenu = NSMenu()
        popupMenu.autoenablesItems = false
        popupMenu.delegate = self
        bookmarksPopup.menu = popupMenu
        bookmarksPopup.toolTip = "Bookmarks"
        // Populate once now so the button face shows "Bookmarks" at launch
        // (the delegate only fires when the menu is about to open).
        BookmarksMenuBuilder.populate(popupMenu,
                                      entries: audioEngine.bookmarkMenuEntries,
                                      leadingTitle: "Bookmarks")

        timeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        zoomOutButton.image = NSImage(systemSymbolName: "minus.magnifyingglass",
                                      accessibilityDescription: "Zoom out")
        zoomOutButton.bezelStyle = .rounded
        zoomOutButton.target = self
        zoomOutButton.action = #selector(zoomOutTapped(_:))
        zoomOutButton.toolTip = "Zoom out (Cmd+scroll)"

        zoomInButton.image = NSImage(systemSymbolName: "plus.magnifyingglass",
                                     accessibilityDescription: "Zoom in")
        zoomInButton.bezelStyle = .rounded
        zoomInButton.target = self
        zoomInButton.action = #selector(zoomInTapped(_:))
        zoomInButton.toolTip = "Zoom in (Cmd+scroll · double-click waveform to reset)"

        let scopeConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        followButton.image = NSImage(systemSymbolName: "scope",
                                     accessibilityDescription: "Follow playhead")?
            .withSymbolConfiguration(scopeConfig)
        // Borderless + custom layer background gives us a clear lit chip; the
        // standard bezel applied its own appearance over `contentTintColor`,
        // washing the lit / dim distinction out.
        followButton.isBordered = false
        followButton.wantsLayer = true
        followButton.layer?.cornerRadius = 5
        followButton.layer?.masksToBounds = true
        followButton.target = self
        followButton.action = #selector(followTapped(_:))
        followButton.toolTip = "Follow playhead — scrolling disables, click re-enables"
        followButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        followButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
        setFollowPlayhead(on: true)   // initially lit

        // Filename + a smaller file-info line beneath it, pushed to the
        // trailing edge by a spacer. Both truncate before crowding the row.
        // Colours come from the current theme and refresh via the notification.
        fileInfoLabel.textColor = ThemeManager.shared.filenameColor.withAlphaComponent(0.85)
        fileInfoLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for label in [statusLabel, fileInfoLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let fileBlock = NSStackView(views: [statusLabel, fileInfoLabel])
        fileBlock.orientation = .vertical
        fileBlock.alignment = .leading
        fileBlock.spacing = 1

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [
            playButton, stopButton, loopButton, bookmarkButton, bookmarksPopup, timeLabel,
            zoomInButton, zoomOutButton, followButton,
            spacer, fileBlock
        ])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func updateTimeLabel(currentFrame: AVAudioFramePosition) {
        let rate = audioEngine.sampleRate
        let current = Double(currentFrame) / rate
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
        audioEngine.loopMode = (sender.state == .on)
    }

    @objc private func addBookmark(_ sender: NSButton) {
        audioEngine.addBookmarkAtPlayhead()
    }

    @objc private func zoomInTapped(_ sender: NSButton) { onZoomIn?() }
    @objc private func zoomOutTapped(_ sender: NSButton) { onZoomOut?() }
    @objc private func followTapped(_ sender: NSButton) { onFollowTapped?() }

    /// Update the follow button's glow to match the waveform's actual state.
    func setFollowPlayhead(on: Bool) {
        followIsOn = on
        followButton.contentTintColor = on ? Self.followOnFg : Self.followOffFg
        followButton.layer?.backgroundColor =
            (on ? ThemeManager.shared.followOnColor : NSColor.clear).cgColor
        // Belt-and-suspenders: a clearly different overall opacity in case
        // contentTintColor / layer background aren't producing visible
        // differentiation on a given system.
        followButton.alphaValue = on ? 1.0 : 0.55
    }

    /// Re-applied when the user picks a different theme.
    private func applyTheme() {
        let theme = ThemeManager.shared
        statusLabel.textColor = theme.filenameColor
        fileInfoLabel.textColor = theme.filenameColor.withAlphaComponent(0.85)
        setFollowPlayhead(on: followIsOn)   // refreshes the chip's bg colour
    }
}

extension TransportView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        BookmarksMenuBuilder.populate(menu,
                                      entries: audioEngine.bookmarkMenuEntries,
                                      leadingTitle: "Bookmarks")
    }
}
