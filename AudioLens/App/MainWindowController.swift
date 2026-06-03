import AppKit
import UniformTypeIdentifiers

/// Window subclass that intercepts plain Tab in `sendEvent` and forwards it
/// to the controller. NSEvent's local key monitor approach trips Swift 6's
/// Sendable checking when reaching back into a MainActor-isolated controller,
/// and a "\t" menu key equivalent never fires because AppKit's key-view focus
/// loop consumes Tab first. Subclassing skips both problems: sendEvent runs
/// on the main thread by definition (no Sendable closure crossing) and
/// catches the event before any responder processing.
/// Window subclass that intercepts every keyDown in `sendEvent`, looks the
/// event up against KeyBindings.shared, and dispatches the matching action to
/// the controller. The override is a regular @MainActor method, so no
/// Sendable closure boundary to worry about. It also catches the event before
/// AppKit's responder chain consumes special keys like Tab.
@MainActor
final class AudioLensWindow: NSWindow {
    var onKeyboardAction: ((KeyboardAction) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           let action = KeyBindings.shared.action(for: event) {
            onKeyboardAction?(action)
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {

    private let audioEngine = AudioEngine()
    private let rootViewController: MainViewController

    init() {
        rootViewController = MainViewController(audioEngine: audioEngine)

        let window = AudioLensWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "AudioLens"
        window.titlebarAppearsTransparent = false
        window.contentViewController = rootViewController
        // Below this size the EQ row's height (computed from the residual
        // space after the waveform / transport / pitch-time bands) becomes
        // negative and AppKit logs "Invalid view geometry" warnings.
        window.contentMinSize = NSSize(width: 900, height: 640)
        window.center()

        super.init(window: window)
        window.delegate = self
        window.onKeyboardAction = { [weak self] action in
            self?.dispatch(action)
        }
        rootViewController.onOpenFile = { [weak self] url in
            self?.openURL(url)
        }
    }

    private func dispatch(_ action: KeyboardAction) {
        switch action {
        case .playPause:      audioEngine.togglePlayPause()
        case .stop:           audioEngine.stop()
        case .goToStart:      audioEngine.seekToStart()
        case .seekBack2_5:    audioEngine.seekRelative(seconds: -2.5)
        case .seekForward2_5: audioEngine.seekRelative(seconds: 2.5)
        case .seekBack5:      audioEngine.seekRelative(seconds: -5)
        case .seekForward5:   audioEngine.seekRelative(seconds: 5)
        case .seekBack10:     audioEngine.seekRelative(seconds: -10)
        case .seekForward10:  audioEngine.seekRelative(seconds: 10)
        case .seekBack30:     audioEngine.seekRelative(seconds: -30)
        case .seekForward30:  audioEngine.seekRelative(seconds: 30)
        case .addBookmark:      audioEngine.addBookmarkAtPlayhead()
        case .nextBookmark:     audioEngine.goToNextBookmark()
        case .previousBookmark: audioEngine.goToPreviousBookmark()
        case .lastBookmark:     audioEngine.goToLastBookmark()
        case .firstBookmark:    audioEngine.goToFirstBookmark()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc func openFile(_ sender: Any?) {
        Task {
            guard let window = self.window else { return }
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowedContentTypes = AudioFileLoader.supportedContentTypes

            let response = await panel.beginSheetModal(for: window)
            guard response == .OK, let url = panel.url else { return }
            openURL(url)
        }
    }

    @objc func openRecentFile(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openURL(url)
    }

    /// Single entry point for opening a file from any source — Open panel,
    /// Open Recent, a window drop, or a Dock drop. Wraps the load in
    /// security-scoped access so sandboxed reopen / recent / drop URLs resolve.
    func openURL(_ url: URL) {
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            await load(url: url)
        }
    }

    @objc func togglePlayPause(_ sender: Any?) {
        audioEngine.togglePlayPause()
    }

    @objc func stopPlayback(_ sender: Any?) {
        audioEngine.stop()
    }

    @objc func goToStart(_ sender: Any?) {
        audioEngine.seekToStart()
    }

    // MARK: - Bookmark actions (menu)

    @objc func addBookmark(_ sender: Any?) { audioEngine.addBookmarkAtPlayhead() }
    @objc func nextBookmark(_ sender: Any?) { audioEngine.goToNextBookmark() }
    @objc func previousBookmark(_ sender: Any?) { audioEngine.goToPreviousBookmark() }
    @objc func firstBookmark(_ sender: Any?) { audioEngine.goToFirstBookmark() }
    @objc func lastBookmark(_ sender: Any?) { audioEngine.goToLastBookmark() }
    @objc func clearBookmarks(_ sender: Any?) { audioEngine.clearBookmarks() }

    @objc func openBookmark(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        audioEngine.goToBookmark(at: number.int64Value)
    }

    /// Bookmarks as (frame, timecode label) for the Bookmarks menu.
    var bookmarkEntries: [(frame: AVAudioFramePosition, label: String)] {
        let rate = audioEngine.sampleRate
        return audioEngine.bookmarks.map { frame in
            (frame, Self.formatTimecode(Double(frame) / rate))
        }
    }

    /// hh:mm:ss:xx where xx is hundredths of a second.
    static func formatTimecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00:00:00" }
        let totalHundredths = Int((seconds * 100).rounded())
        let hundredths = totalHundredths % 100
        let totalSeconds = totalHundredths / 100
        let s = totalSeconds % 60
        let m = (totalSeconds / 60) % 60
        let h = totalSeconds / 3600
        return String(format: "%02d:%02d:%02d:%02d", h, m, s, hundredths)
    }

    private func load(url: URL) async {
        do {
            try await audioEngine.load(url: url)
            rootViewController.didLoadAudio()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            showError(error)
        }
    }

    private func showError(_ error: any Error) {
        guard let window else { return }
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
}
