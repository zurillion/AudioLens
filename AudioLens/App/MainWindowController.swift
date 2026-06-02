import AppKit
import UniformTypeIdentifiers

/// Window subclass that intercepts plain Tab in `sendEvent` and forwards it
/// to the controller. NSEvent's local key monitor approach trips Swift 6's
/// Sendable checking when reaching back into a MainActor-isolated controller,
/// and a "\t" menu key equivalent never fires because AppKit's key-view focus
/// loop consumes Tab first. Subclassing skips both problems: sendEvent runs
/// on the main thread by definition (no Sendable closure crossing) and
/// catches the event before any responder processing.
@MainActor
final class AudioLensWindow: NSWindow {
    var onTabKey: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.keyCode == 48,  // Tab
           !event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.option),
           !event.modifierFlags.contains(.control) {
            onTabKey?()
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
        window.contentMinSize = NSSize(width: 800, height: 520)
        window.center()

        super.init(window: window)
        window.delegate = self
        window.onTabKey = { [weak self] in
            self?.audioEngine.seekToStart()
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
            await load(url: url)
        }
    }

    @objc func openRecentFile(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Task {
            // Bookmarks resolved by NSDocumentController are session-valid,
            // but we still ask for security-scoped access in case the URL
            // came from a different scope.
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
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
